import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Sign-in against the Docker Server", .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct SignInIntegrationTests {
    let client = AudiobookshelfClient()

    @Test("Status reports a supported version with local sign-in")
    func status() async throws {
        let server = try IntegrationServer.current()
        let status = try await client.status(of: server.baseURL)
        #expect(status.reportedVersion == "2.37.1")
        #expect(status.isSupported)
        #expect(status.allowsLocalSignIn)
    }

    @Test("Login returns a token pair whose lifetimes come from the JWT")
    func logIn() async throws {
        let server = try IntegrationServer.current()
        let user = try await client.logIn(
            to: server.baseURL, username: server.user.username, password: server.user.password)
        #expect(user.username == server.user.username)
        let now = Date()
        let access = try #require(user.tokens.accessTokenExpiry).timeIntervalSince(now)
        let refresh = try #require(user.tokens.refreshTokenExpiry).timeIntervalSince(now)
        // Server defaults: access 1 h, refresh 30 d.
        #expect((3500...3700).contains(access))
        #expect((29 * 86400...31 * 86400).contains(refresh))
    }

    @Test("A wrong password is a 401")
    func wrongPassword() async throws {
        let server = try IntegrationServer.current()
        await #expect(throws: ServerAPIError.unauthorized) {
            try await client.logIn(to: server.baseURL, username: server.user.username, password: "not-the-password")
        }
    }

    @Test("The Library list includes the fixture book Library")
    func libraries() async throws {
        let server = try IntegrationServer.current()
        let user = try await client.logIn(
            to: server.baseURL, username: server.user.username, password: server.user.password)
        let libraries = try await client.libraries(on: server.baseURL, accessToken: user.tokens.accessToken)
        #expect(libraries.contains(ServerLibrary(id: server.libraryID, name: "Fixtures", mediaType: .book)))
    }

    @Test("Refresh rotates the pair, and an unknown refresh token is a 401")
    func refresh() async throws {
        let server = try IntegrationServer.current()
        let user = try await client.logIn(
            to: server.baseURL, username: server.user.username, password: server.user.password)
        let refreshed = try await client.refresh(on: server.baseURL, refreshToken: user.tokens.refreshToken)
        #expect(refreshed.id == user.id)
        #expect(refreshed.tokens.refreshToken != user.tokens.refreshToken)
        await #expect(throws: ServerAPIError.unauthorized) {
            try await client.refresh(on: server.baseURL, refreshToken: "not-a-refresh-token")
        }
    }

    @Test("Signing in picks the only book Library and saves the identity and tokens")
    func signIn() async throws {
        let server = try IntegrationServer.current()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let tokens = InMemoryTokenStore()

        let signIn = SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
        let result = try await signIn.signIn(
            address: server.baseURL.absoluteString,
            username: server.user.username,
            password: server.user.password
        )

        guard case .signedIn(let identity) = result else {
            Issue.record("expected to be signed in, got \(result)")
            return
        }
        #expect(identity.libraryID == server.libraryID)
        #expect(identity.libraryName == "Fixtures")
        #expect(identity.username == server.user.username)
        #expect(try database.serverIdentity() == identity)
        let saved = try #require(try tokens.load())
        _ = try await client.libraries(on: server.baseURL, accessToken: saved.accessToken)
    }

    @Test("Auth refreshes on a real 401 and saves the rotated pair")
    func authRefreshesOn401() async throws {
        let server = try IntegrationServer.current()
        let user = try await client.logIn(
            to: server.baseURL, username: server.user.username, password: server.user.password)
        // A pair whose access token the Server rejects, with a good refresh token.
        let tokens = InMemoryTokenStore(TokenPair(accessToken: "rejected", refreshToken: user.tokens.refreshToken))
        let auth = Auth(server: server.baseURL, api: client, tokenStore: tokens, clock: SystemClock())

        let client = client
        let libraries = try await auth.authorized { token throws(ServerAPIError) in
            try await client.libraries(on: server.baseURL, accessToken: token)
        }

        #expect(libraries.contains { $0.id == server.libraryID })
        let saved = try #require(try tokens.load())
        #expect(saved.accessToken != "rejected")
        #expect(saved.refreshToken != user.tokens.refreshToken)
    }
}
