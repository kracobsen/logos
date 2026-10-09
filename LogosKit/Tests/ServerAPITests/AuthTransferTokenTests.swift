import Domain
import Foundation
import ServerAPI
import Testing

/// Tokens for background file transfers, which carry the token in the request rather than calling through ``Auth``.
@Suite("Auth for file transfers")
struct AuthTransferTokenTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()

    init() {
        server = FakeServer(clock: clock)
    }

    func signedIn() async throws -> TokenPair {
        let pair = try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens
        try tokens.save(pair)
        return pair
    }

    func auth() -> Auth {
        Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
    }

    var refreshCount: Int {
        server.requests.filter { if case .refresh = $0 { true } else { false } }.count
    }

    @Test("A token that stays valid long enough is used as it is")
    func longEnough() async throws {
        let pair = try await signedIn()
        await clock.advance(by: .seconds(3600 - 11 * 60))

        let token = try await auth().accessToken(validFor: .seconds(10 * 60))

        #expect(token == pair.accessToken)
        #expect(refreshCount == 0)
    }

    @Test("A token with less than the asked-for time left is refreshed first, and the new pair saved")
    func refreshedAhead() async throws {
        let pair = try await signedIn()
        await clock.advance(by: .seconds(3600 - 9 * 60))

        let token = try await auth().accessToken(validFor: .seconds(10 * 60))

        #expect(token != pair.accessToken)
        #expect(refreshCount == 1)
        #expect(try tokens.load()?.accessToken == token)
    }

    @Test("After a 401, concurrent callers share one refresh")
    func rejectedSharesOneRefresh() async throws {
        let pair = try await signedIn()
        server.revokeAccessTokens()
        let auth = auth()

        async let first = auth.accessToken(replacingRejected: pair.accessToken)
        async let second = auth.accessToken(replacingRejected: pair.accessToken)
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(a != pair.accessToken)
        #expect(refreshCount == 1)
    }

    @Test("A rejected token that was already replaced isn't refreshed again")
    func alreadyReplaced() async throws {
        let pair = try await signedIn()
        let auth = auth()
        let replacement = try await auth.accessToken(replacingRejected: pair.accessToken)

        let again = try await auth.accessToken(replacingRejected: pair.accessToken)

        #expect(again == replacement)
        #expect(refreshCount == 1)
    }

    @Test("A rejected refresh means Needs sign-in")
    func needsSignIn() async throws {
        let pair = try await signedIn()
        server.revokeRefreshTokens()

        await #expect(throws: AuthError.needsSignIn) {
            try await auth().accessToken(replacingRejected: pair.accessToken)
        }
    }
}
