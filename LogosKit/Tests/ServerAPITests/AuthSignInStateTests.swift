import Domain
import Foundation
import ServerAPI
import Testing

@Suite("Auth: needs sign-in, signing in again and signing out")
struct AuthSignInStateTests {
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

    func call(_ auth: Auth) async throws(AuthError) -> String {
        let server = server
        return try await auth.authorized { token throws(ServerAPIError) in
            _ = try await server.libraries(on: server.address, accessToken: token)
            return token
        }
    }

    /// Enters needs sign-in the way the Server does it: every token revoked, so the refresh is rejected.
    func rejectRefresh(_ auth: Auth) async {
        server.revokeAccessTokens()
        server.revokeRefreshTokens()
        _ = try? await call(auth)
    }

    @Test("The needs-sign-in updates start with the current state and follow a rejected refresh")
    func updatesFollowRejection() async throws {
        _ = try await signedIn()
        let auth = auth()
        var updates = await auth.needsSignInUpdates().makeAsyncIterator()
        #expect(await updates.next() == false)

        await rejectRefresh(auth)

        #expect(await updates.next() == true)
        #expect(await auth.needsSignIn)
    }

    @Test("Signing in again saves the new pair, leaves needs sign-in, and calls reach the Server with it")
    func signInAgainResumes() async throws {
        _ = try await signedIn()
        let auth = auth()
        await rejectRefresh(auth)
        var updates = await auth.needsSignInUpdates().makeAsyncIterator()
        #expect(await updates.next() == true)

        let fresh = try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens
        try await auth.signedInAgain(with: fresh)

        #expect(await updates.next() == false)
        #expect(try tokens.load() == fresh)
        #expect(try await call(auth) == fresh.accessToken)
    }

    @Test("If the new pair can't be saved, Auth stays in needs sign-in")
    func signInAgainSaveFails() async throws {
        _ = try await signedIn()
        let auth = auth()
        await rejectRefresh(auth)
        let fresh = try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens
        tokens.failSaves = true

        await #expect(throws: AuthError.tokenStoreFailed) { try await auth.signedInAgain(with: fresh) }
        #expect(await auth.needsSignIn)
    }

    @Test("With no tokens stored at all, Auth is in needs sign-in")
    func noTokensIsNeedsSignIn() async {
        let auth = auth()
        _ = try? await call(auth)
        #expect(await auth.needsSignIn)
        #expect(server.requests.isEmpty)
    }

    @Test(
        "Signing out posts the refresh token to /logout, clears the stored pair, and nothing reaches the Server after")
    func signOut() async throws {
        let pair = try await signedIn()
        let auth = auth()

        await auth.signOut()

        #expect(server.requests.last == .logOut(server.address, refreshToken: pair.refreshToken))
        #expect(try tokens.load() == nil)
        let before = server.requests.count
        await #expect(throws: AuthError.needsSignIn) { try await call(auth) }
        #expect(server.requests.count == before)
    }

    @Test("Signing out revokes the refresh token on the Server")
    func signOutRevokes() async throws {
        let pair = try await signedIn()
        await auth().signOut()
        await #expect(throws: ServerAPIError.unauthorized) {
            try await server.refresh(on: server.address, refreshToken: pair.refreshToken)
        }
    }

    @Test("Signing out offline still clears the tokens: /logout is best effort")
    func signOutOffline() async throws {
        _ = try await signedIn()
        server.isReachable = { _ in false }
        await auth().signOut()
        #expect(try tokens.load() == nil)
    }

    @Test("Signing out uses the refresh token Auth holds, even after it rotated")
    func signOutAfterRotation() async throws {
        _ = try await signedIn()
        let auth = auth()
        server.revokeAccessTokens()
        _ = try await call(auth)  // 401, refresh, rotated
        let rotated = try #require(try tokens.load())

        await auth.signOut()

        #expect(server.requests.last == .logOut(server.address, refreshToken: rotated.refreshToken))
    }
}
