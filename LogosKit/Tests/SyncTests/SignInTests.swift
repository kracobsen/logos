import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite("Sign-in")
struct SignInTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    func signIn(
        _ address: String = "abs.example.com",
        username: String = "listener",
        password: String = "listenerpass",
        on server: FakeServer? = nil
    ) async throws(SignInError) -> SignInResult {
        try await SignIn(api: server ?? self.server, tokenStore: tokens, database: database)
            .signIn(address: address, username: username, password: password)
    }

    func signedOut() throws -> Bool {
        try database.serverIdentity() == nil && tokens.load() == nil
    }

    // MARK: The address

    @Test("A bare host gets https:// added")
    func bareHost() async throws {
        _ = try await signIn("abs.example.com")
        #expect(server.requests.first == .status(URL(string: "https://abs.example.com")!))
    }

    @Test(
        "Addresses are tidied before use",
        arguments: [
            "  abs.example.com  ",
            "abs.example.com/",
            "https://abs.example.com",
            "HTTPS://abs.example.com/",
        ]
    )
    func tidied(address: String) async throws {
        _ = try await signIn(address)
        #expect(server.requests.first == .status(URL(string: "https://abs.example.com")!))
    }

    @Test("A Server under a path keeps it")
    func subpath() async throws {
        let server = FakeServer(address: URL(string: "https://example.com/audiobookshelf")!, clock: clock)
        let result = try await signIn("example.com/audiobookshelf/", on: server)
        guard case .signedIn(let identity) = result else { Issue.record("not signed in"); return }
        #expect(identity.serverURL == URL(string: "https://example.com/audiobookshelf")!)
    }

    @Test(
        "Plain HTTP is refused without contacting the Server",
        arguments: ["http://abs.example.com", "ftp://abs.example.com"])
    func httpsOnly(address: String) async {
        await #expect(throws: SignInError.httpsRequired) { try await signIn(address) }
        #expect(server.requests.isEmpty)
    }

    @Test("An empty or malformed address is refused", arguments: ["", "   ", "https://", "abs example.com"])
    func invalid(address: String) async {
        await #expect(throws: SignInError.invalidAddress) { try await signIn(address) }
        #expect(server.requests.isEmpty)
    }

    // MARK: The steps

    @Test("Steps run in order: status, login, then the Library list")
    func order() async throws {
        _ = try await signIn()
        let url = URL(string: "https://abs.example.com")!
        let requests = server.requests
        #expect(requests.count == 3)
        #expect(requests.first == .status(url))
        #expect(requests.dropFirst().first == .logIn(url, username: "listener"))
        guard case .libraries(url, _) = requests.last else {
            Issue.record("expected the Library list last, got \(requests)")
            return
        }
    }

    @Test("Can't reach the Server")
    func unreachable() async throws {
        server.isReachable = { _ in false }
        await #expect(throws: SignInError.cantReachServer) { try await signIn() }
        #expect(try signedOut())
    }

    @Test("Something that isn't audiobookshelf counts as Can't reach the Server")
    func notAudiobookshelf() async throws {
        server.beforeHandling { _ throws(ServerAPIError) in throw .unreadableResponse }
        await #expect(throws: SignInError.cantReachServer) { try await signIn() }
    }

    @Test("Server too old, stating the version found, and no login is attempted")
    func tooOld() async throws {
        server.version = "2.35.1"
        await #expect(throws: SignInError.serverTooOld(found: "2.35.1")) { try await signIn() }
        #expect(server.requests.count == 1)
        #expect(try signedOut())
    }

    @Test("A version that can't be read counts as too old")
    func unreadableVersion() async {
        server.version = "nightly"
        await #expect(throws: SignInError.serverTooOld(found: "nightly")) { try await signIn() }
    }

    @Test("A Server without local sign-in is refused before the password is sent")
    func noLocalSignIn() async {
        server.authMethods = ["openid"]
        await #expect(throws: SignInError.localSignInNotAllowed) { try await signIn() }
        #expect(server.requests.count == 1)
    }

    @Test("Wrong username or password")
    func wrongPassword() async throws {
        await #expect(throws: SignInError.wrongCredentials) { try await signIn(password: "nope") }
        #expect(try signedOut())
    }

    @Test("Too many attempts when the login is rate-limited")
    func rateLimited() async {
        server.beforeHandling { request throws(ServerAPIError) in
            if case .logIn = request { throw .rateLimited }
        }
        await #expect(throws: SignInError.tooManyAttempts) { try await signIn() }
    }

    @Test("No book Library when the Server has only podcast Libraries")
    func noBookLibrary() async throws {
        server.libraries = [ServerLibrary(id: "p", name: "Podcasts", mediaType: .podcast)]
        await #expect(throws: SignInError.noBookLibrary) { try await signIn() }
        #expect(try signedOut())
    }

    // MARK: Choosing the Library

    @Test("A single book Library is picked automatically, podcast Libraries ignored, and the identity saved")
    func singleLibrary() async throws {
        server.libraries = [
            ServerLibrary(id: "p", name: "Podcasts", mediaType: .podcast),
            ServerLibrary(id: "b", name: "Audiobooks", mediaType: .book),
        ]
        let result = try await signIn()
        let expected = ServerIdentity(
            serverURL: URL(string: "https://abs.example.com")!,
            userID: "user-listener",
            username: "listener",
            libraryID: "b",
            libraryName: "Audiobooks"
        )
        #expect(result == .signedIn(expected))
        #expect(try database.serverIdentity() == expected)
        #expect(try tokens.load() != nil)
    }

    @Test("With several book Libraries the user picks one; nothing is saved until then")
    func severalLibraries() async throws {
        server.libraries = [
            ServerLibrary(id: "b1", name: "Fiction", mediaType: .book),
            ServerLibrary(id: "p", name: "Podcasts", mediaType: .podcast),
            ServerLibrary(id: "b2", name: "Non-fiction", mediaType: .book),
        ]
        guard case .chooseLibrary(let choice) = try await signIn() else {
            Issue.record("expected a Library choice")
            return
        }
        #expect(
            choice.libraries == [
                LibraryOption(id: "b1", name: "Fiction"), LibraryOption(id: "b2", name: "Non-fiction"),
            ])
        #expect(try signedOut())

        let identity = try SignIn(api: server, tokenStore: tokens, database: database)
            .choose(LibraryOption(id: "b2", name: "Non-fiction"), from: choice)
        #expect(identity.libraryID == "b2")
        #expect(try database.serverIdentity() == identity)
        #expect(try tokens.load() != nil)
    }

    @Test("The tokens saved are the ones the Server issued, and they work")
    func savedTokensWork() async throws {
        _ = try await signIn()
        let saved = try #require(try tokens.load())
        _ = try await server.libraries(on: server.address, accessToken: saved.accessToken)
    }

    @Test("The password is never stored")
    func passwordNeverStored() async throws {
        let password = "unmistakable-password-7f3a"
        server.accounts = [FakeServer.Account(id: "u", username: "listener", password: password)]
        _ = try await signIn(password: password)
        let saved = try #require(try tokens.load())
        #expect(!saved.accessToken.contains(password) && !saved.refreshToken.contains(password))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.firstRange(of: Data(password.utf8)) == nil, "found the password in \(file.lastPathComponent)")
        }
    }

    // MARK: Loopback for integration tests

    @Test("Plain HTTP to a loopback Server is allowed only when asked for (integration tests)")
    func loopbackHTTP() async throws {
        let local = FakeServer(address: URL(string: "http://127.0.0.1:13378")!, clock: clock)
        let strict = SignIn(api: local, tokenStore: tokens, database: database)
        await #expect(throws: SignInError.httpsRequired) {
            try await strict.signIn(address: "http://127.0.0.1:13378", username: "listener", password: "listenerpass")
        }
        let relaxed = SignIn(api: local, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
        _ = try await relaxed.signIn(address: "http://127.0.0.1:13378", username: "listener", password: "listenerpass")
        await #expect(throws: SignInError.httpsRequired) {
            try await relaxed.signIn(address: "http://abs.example.com", username: "listener", password: "listenerpass")
        }
    }
}
