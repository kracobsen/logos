import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

/// Needs sign-in and sign-out against the real Server. Each test revokes only the session it made itself (by
/// logging out its own refresh token), so the shared Server's other sessions are untouched. No progress is written.
@Suite(
    "Needs sign-in and sign-out against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct NeedsSignInIntegrationTests {
    let client = AudiobookshelfClient()

    func signedIn(_ server: IntegrationServer) async throws -> (AppDatabase, InMemoryTokenStore) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let tokens = InMemoryTokenStore()
        _ = try await signIn(server, tokens: tokens, database: database)
            .signIn(
                address: server.baseURL.absoluteString, username: server.user.username,
                password: server.user.password)
        return (database, tokens)
    }

    func signIn(_ server: IntegrationServer, tokens: InMemoryTokenStore, database: AppDatabase) -> SignIn {
        SignIn(
            api: AudiobookshelfClient(session: server.session), tokenStore: tokens, database: database,
            allowsPlainHTTPOnLoopback: true)
    }

    @Test("POST /logout revokes the refresh token: refreshing with it is then a 401")
    func logOutRevokes() async throws {
        let server = try IntegrationServer.current()
        let user = try await client.logIn(
            to: server.baseURL, username: server.user.username, password: server.user.password)

        try await client.logOut(on: server.baseURL, refreshToken: user.tokens.refreshToken)

        await #expect(throws: ServerAPIError.unauthorized) {
            try await client.refresh(on: server.baseURL, refreshToken: user.tokens.refreshToken)
        }
    }

    @Test("A revoked sign-in enters needs sign-in; signing in again as the same user resumes sync")
    func needsSignInAndBack() async throws {
        let server = try IntegrationServer.current()
        let (database, tokens) = try await signedIn(server)
        let stored = try #require(try tokens.load())
        // The session is revoked elsewhere, and the access token is no longer accepted.
        try await client.logOut(on: server.baseURL, refreshToken: stored.refreshToken)
        try tokens.save(TokenPair(accessToken: "rejected", refreshToken: stored.refreshToken))
        let auth = Auth(server: server.baseURL, api: client, tokenStore: tokens, clock: SystemClock())
        let sync = LibrarySync(database: database, api: client, auth: auth, clock: SystemClock())

        #expect(await sync.sync(.manual) == .needsSignIn)
        #expect(await sync.connection.state == .needsSignIn)

        try await sync.connection.signInAgain(
            using: signIn(server, tokens: tokens, database: database), address: server.baseURL.absoluteString,
            username: server.user.username, password: server.user.password)

        #expect(await sync.connection.state == .signedIn)
        #expect(await sync.sync(.manual) == .synced)
        await auth.signOut()
    }

    @Test("Signing out revokes the sign-in on the Server and clears the tokens")
    func signOut() async throws {
        let server = try IntegrationServer.current()
        let (_, tokens) = try await signedIn(server)
        let stored = try #require(try tokens.load())
        let auth = Auth(server: server.baseURL, api: client, tokenStore: tokens, clock: SystemClock())

        await auth.signOut()

        #expect(try tokens.load() == nil)
        await #expect(throws: ServerAPIError.unauthorized) {
            try await client.refresh(on: server.baseURL, refreshToken: stored.refreshToken)
        }
    }
}
