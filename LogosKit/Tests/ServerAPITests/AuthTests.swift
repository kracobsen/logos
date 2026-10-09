import Domain
import Foundation
import ServerAPI
import Synchronization
import Testing

@Suite("Auth")
struct AuthTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()

    init() {
        server = FakeServer(clock: clock)
    }

    /// Signs the fixture user in on the fake Server and stores the pair, as sign-in does.
    func signedIn() async throws -> TokenPair {
        let pair = try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens
        try tokens.save(pair)
        return pair
    }

    func auth() -> Auth {
        Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
    }

    /// An authenticated call through `auth`, returning the token the Server saw.
    func call(_ auth: Auth) async throws(AuthError) -> String {
        let server = server
        return try await auth.authorized { token throws(ServerAPIError) in
            _ = try await server.libraries(on: server.address, accessToken: token)
            return token
        }
    }

    var refreshCount: Int {
        server.requests.filter { if case .refresh = $0 { true } else { false } }.count
    }

    @Test("Calls use the stored access token")
    func usesStoredToken() async throws {
        let pair = try await signedIn()
        #expect(try await call(auth()) == pair.accessToken)
        #expect(refreshCount == 0)
    }

    @Test("With no tokens stored, calls need sign-in and nothing reaches the Server")
    func noTokens() async {
        await #expect(throws: AuthError.needsSignIn) { try await call(auth()) }
        #expect(server.requests.isEmpty)
    }

    @Test("More than 5 minutes left on the access token: no refresh")
    func freshTokenNotRefreshed() async throws {
        _ = try await signedIn()
        await clock.advance(by: .seconds(3600 - 301))
        _ = try await call(auth())
        #expect(refreshCount == 0)
    }

    @Test("Under 5 minutes left: refreshed first, and the rotated pair is saved and used")
    func refreshesAhead() async throws {
        let old = try await signedIn()
        await clock.advance(by: .seconds(3600 - 299))
        let used = try await call(auth())
        #expect(refreshCount == 1)
        let saved = try #require(try tokens.load())
        #expect(saved != old)
        #expect(saved.refreshToken != old.refreshToken)
        #expect(used == saved.accessToken)
    }

    @Test("The 5 minutes come from the JWT's own lifetime, not a hard-coded hour")
    func lifetimeFromJWT() async throws {
        let shortLived = FakeServer(clock: clock, accessTokenLifetime: .seconds(600))
        let pair = try await shortLived.logIn(to: shortLived.address, username: "listener", password: "listenerpass")
        try tokens.save(pair.tokens)
        let auth = Auth(server: shortLived.address, api: shortLived, tokenStore: tokens, clock: clock)
        await clock.advance(by: .seconds(301))
        _ = try await auth.authorized { token throws(ServerAPIError) in
            try await shortLived.libraries(on: shortLived.address, accessToken: token)
        }
        #expect(shortLived.requests.contains { if case .refresh = $0 { true } else { false } })
    }

    @Test("A 401 triggers a refresh and the call is retried once with the new token")
    func refreshesOn401() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        let used = try await call(auth())
        #expect(refreshCount == 1)
        #expect(used == (try tokens.load())?.accessToken)
    }

    @Test("Concurrent 401s share one refresh")
    func sharedRefresh() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        // Hold the refresh open until every caller has hit its 401, so they all have to wait on it.
        let gate = Gate()
        server.beforeHandling { request throws(ServerAPIError) in
            if case .refresh = request { await gate.wait() }
        }
        let auth = auth()
        let used = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await call(auth) }
            }
            while server.requests.count(where: { if case .libraries = $0 { true } else { false } }) < 5 {
                await Task.yield()
            }
            await gate.open()
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(refreshCount == 1)
        #expect(used == [try tokens.load()?.accessToken])
    }

    @Test("The rotated pair is saved before any request uses it")
    func savedBeforeUse() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        let storeAtUse = Mutex<[String?]>([])
        let tokens = tokens
        server.beforeHandling { request throws(ServerAPIError) in
            if case .libraries = request {
                let stored = try? tokens.load()?.accessToken
                storeAtUse.withLock { $0.append(stored) }
            }
        }
        let used = try await call(auth())
        // The second libraries request (the retry) found the new token already in the store.
        #expect(storeAtUse.withLock { $0.last } == used)
    }

    @Test("If the pair can't be saved, it isn't used")
    func saveFailureStops() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        tokens.failSaves = true
        await #expect(throws: AuthError.tokenStoreFailed) { try await call(auth()) }
        #expect(server.requests.count(where: { if case .libraries = $0 { true } else { false } }) == 1)
    }

    @Test("A refresh that fails on the network isn't retried in a loop, but is tried again at the next trigger")
    func networkFailureRetriedAtNextTrigger() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        server.isReachable = { request in if case .refresh = request { false } else { true } }
        let auth = auth()
        await #expect(throws: AuthError.server(.unreachable("The fake Server is unreachable"))) {
            try await call(auth)
        }
        #expect(refreshCount == 1)

        server.isReachable = { _ in true }
        _ = try await call(auth)
        #expect(refreshCount == 2)
    }

    @Test("A rate-limited refresh isn't Needs sign-in, and is tried again at the next trigger")
    func rateLimitedRefresh() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        let limited = Mutex(true)
        server.beforeHandling { request throws(ServerAPIError) in
            if case .refresh = request, limited.withLock({ $0 }) { throw .rateLimited }
        }
        let auth = auth()
        await #expect(throws: AuthError.server(.rateLimited)) { try await call(auth) }
        limited.withLock { $0 = false }
        _ = try await call(auth)
        #expect(refreshCount == 2)
    }

    @Test("An ahead-of-time refresh that fails on the network still uses the unexpired token")
    func aheadOfTimeFailureFallsBack() async throws {
        let pair = try await signedIn()
        await clock.advance(by: .seconds(3600 - 60))
        server.isReachable = { request in if case .refresh = request { false } else { true } }
        #expect(try await call(auth()) == pair.accessToken)
    }

    @Test("A rejected refresh means Needs sign-in, and later calls don't reach the Server")
    func rejectedRefresh() async throws {
        _ = try await signedIn()
        server.revokeAccessTokens()
        server.revokeRefreshTokens()
        let auth = auth()
        await #expect(throws: AuthError.needsSignIn) { try await call(auth) }
        let requestsAfter = server.requests.count
        await #expect(throws: AuthError.needsSignIn) { try await call(auth) }
        #expect(server.requests.count == requestsAfter)
        #expect(await auth.needsSignIn)
    }

    @Test("A 401 straight after a successful refresh is returned, not retried again")
    func noLoopOnRepeated401() async throws {
        _ = try await signedIn()
        server.beforeHandling { request throws(ServerAPIError) in
            if case .libraries = request { throw .unauthorized }
        }
        await #expect(throws: AuthError.server(.unauthorized)) { try await call(auth()) }
        #expect(refreshCount == 1)
    }
}

/// Holds tasks until opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
