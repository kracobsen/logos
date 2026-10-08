import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Sign-in screen")
@MainActor
struct SignInModelTests {
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

    func model() -> SignInModel {
        let model = SignInModel(signIn: SignIn(api: server, tokenStore: tokens, database: database))
        model.address = "abs.example.com"
        model.username = "listener"
        model.password = "listenerpass"
        return model
    }

    @Test("Sign-in needs all three fields")
    func needsFields() {
        let model = model()
        #expect(model.canSubmit)
        model.password = ""
        #expect(!model.canSubmit)
    }

    @Test("Signing in saves the identity and forgets the password")
    func signsIn() async throws {
        let model = model()
        await model.submit()
        #expect(model.error == nil)
        #expect(model.password.isEmpty)
        #expect(try database.serverIdentity()?.username == "listener")
    }

    @Test("Errors appear in place, next to the field that caused them")
    func errorsInPlace() async {
        let model = model()
        model.password = "wrong"
        await model.submit()
        #expect(model.error == .wrongCredentials)
        #expect(model.errorPlacement == .credentials)
        #expect(model.errorMessage == "Wrong username or password.")
        #expect(!model.isWorking)

        server.isReachable = { _ in false }
        await model.submit()
        #expect(model.errorPlacement == .address)
        #expect(model.errorMessage == "Can't reach the Server. Check the address and your connection.")
    }

    @Test("Server too old states the version found")
    func tooOldMessage() async {
        server.version = "2.35.4"
        let model = model()
        await model.submit()
        #expect(model.errorMessage == "Server too old: it runs audiobookshelf 2.35.4, and Logos needs 2.36 or later.")
    }

    @Test("No book Library")
    func noBookLibraryMessage() async {
        server.libraries = [ServerLibrary(id: "p", name: "Podcasts", mediaType: .podcast)]
        let model = model()
        await model.submit()
        #expect(model.errorMessage == "No book Library: this account can't see any audiobook Library on the Server.")
    }

    @Test("With several book Libraries the user picks one, then is signed in")
    func picksLibrary() async throws {
        server.libraries = [
            ServerLibrary(id: "b1", name: "Fiction", mediaType: .book),
            ServerLibrary(id: "b2", name: "Non-fiction", mediaType: .book),
        ]
        let model = model()
        await model.submit()
        #expect(model.libraryOptions.map(\.name) == ["Fiction", "Non-fiction"])
        #expect(try database.serverIdentity() == nil)

        model.choose(LibraryOption(id: "b2", name: "Non-fiction"))
        #expect(model.libraryOptions.isEmpty)
        #expect(try database.serverIdentity()?.libraryID == "b2")
    }
}

@Suite("Launch")
@MainActor
struct LaunchModelTests {
    @Test("Launch shows sign-in when signed out, and the tab shell once an identity is saved")
    func followsIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))

        let model = LaunchModel(database: database)
        #expect(model.identity == nil)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        let identity = ServerIdentity(
            serverURL: URL(string: "https://abs.example.com")!,
            userID: "u",
            username: "listener",
            libraryID: "b",
            libraryName: "Audiobooks"
        )
        try database.saveServerIdentity(identity)
        for _ in 0..<500 where model.identity == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.identity == identity)

        // A later launch skips sign-in straight away.
        #expect(LaunchModel(database: database).identity == identity)
    }
}
