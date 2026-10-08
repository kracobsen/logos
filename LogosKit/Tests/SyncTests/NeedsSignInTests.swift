import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

extension SignedInFixture {
    /// The Server rejects every token: the next call that refreshes enters needs sign-in.
    func rejectSignIn() {
        server.revokeAccessTokens()
        server.revokeRefreshTokens()
    }

    func signIn() -> SignIn {
        SignIn(api: server, tokenStore: tokens, database: database)
    }

    var logOutTokens: [String] {
        server.requests.compactMap { if case .logOut(_, let token) = $0 { token } else { nil } }
    }

    func requestCount(_ matches: (FakeServer.Request) -> Bool) -> Int {
        server.requests.filter(matches).count
    }
}

@Suite("Needs sign-in")
struct NeedsSignInTests {
    @Test("A rejected refresh enters needs sign-in: the connection says so, and sync stops")
    func entering() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("A")])
        let sync = fixture.librarySync()
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .signedIn)

        fixture.rejectSignIn()
        #expect(await sync.sync(.manual) == .needsSignIn)

        #expect(await sync.connection.state == .needsSignIn)
        #expect(await states.next() == .needsSignIn)
    }

    @Test("In needs sign-in the outbox keeps recording and pauses sending; nothing reaches the Server")
    func outboxPauses() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)
        let before = fixture.server.requests.count

        try await fixture.listen("a", from: 0, for: 30)

        #expect(await sync.outbox.send() == .needsSignIn)
        #expect(fixture.server.requests.count == before)
        #expect(try fixture.database.listeningSessions().count == 1)
    }

    @Test("Signing in again as the same user resumes: the outbox sends what it recorded, and sync runs")
    func signInAgainResumes() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)
        try await fixture.listen("a", from: 0, for: 30)
        let identity = try fixture.database.serverIdentity()
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .needsSignIn)

        try await sync.connection.signInAgain(
            using: fixture.signIn(), address: "abs.example.com", username: "listener", password: "listenerpass")

        #expect(await states.next() == .signedIn)
        #expect(await sync.outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(await sync.sync(.manual) == .synced)
        #expect(try fixture.database.serverIdentity() == identity)
    }

    @Test("Signing in again leaves the Library, progress and outbox untouched")
    func noDataTouched() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let sync = fixture.librarySync()
        try await fixture.listen("a", from: 0, for: 30)
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)
        let rows = try fixture.database.libraryRows()
        let sessions = try fixture.database.listeningSessions()
        let progress = try fixture.database.progress(ofBook: "a")

        try await sync.connection.signInAgain(
            using: fixture.signIn(), address: "abs.example.com", username: "listener", password: "listenerpass")

        #expect(try fixture.database.libraryRows() == rows)
        #expect(try fixture.database.listeningSessions() == sessions)
        #expect(try fixture.database.progress(ofBook: "a") == progress)
    }

    @Test("A different user is refused from the sheet: the new sign-in is logged out and nothing changes")
    func differentUser() async throws {
        let fixture = try await SignedInFixture()
        fixture.server.accounts.append(.init(id: "user-other", username: "other", password: "otherpass"))
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)
        let stored = try fixture.tokens.load()

        await #expect(throws: SignInError.differentUser) {
            try await sync.connection.signInAgain(
                using: fixture.signIn(), address: "abs.example.com", username: "other", password: "otherpass")
        }

        #expect(fixture.logOutTokens.count == 1)
        #expect(try fixture.tokens.load() == stored)
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .needsSignIn)
    }

    @Test("A different Server is refused from the sheet before anything is sent")
    func differentServer() async throws {
        let fixture = try await SignedInFixture()
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)
        let before = fixture.server.requests.count

        await #expect(throws: SignInError.differentServer) {
            try await sync.connection.signInAgain(
                using: fixture.signIn(), address: "other.example.com", username: "listener",
                password: "listenerpass")
        }
        #expect(fixture.server.requests.count == before)
    }

    @Test("The same Server typed differently (case, trailing slash) is accepted")
    func sameServerTypedDifferently() async throws {
        let fixture = try await SignedInFixture()
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)

        try await sync.connection.signInAgain(
            using: fixture.signIn(), address: "https://ABS.example.com/", username: "LISTENER",
            password: "listenerpass")
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .signedIn)
    }

    @Test("A wrong password in the sheet is shown in place and leaves needs sign-in")
    func wrongPassword() async throws {
        let fixture = try await SignedInFixture()
        let sync = fixture.librarySync()
        fixture.rejectSignIn()
        _ = await sync.sync(.manual)

        await #expect(throws: SignInError.wrongCredentials) {
            try await sync.connection.signInAgain(
                using: fixture.signIn(), address: "abs.example.com", username: "listener", password: "nope")
        }
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .needsSignIn)
    }
}

@Suite("Server too old")
struct ServerTooOldTests {
    @Test("A Server downgraded below 2.36 stops sync, and the connection says which version it found")
    func downgraded() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("A")])
        let sync = fixture.librarySync()
        #expect(await sync.sync(.manual) == .synced)
        var states = await sync.connection.updates().makeAsyncIterator()
        #expect(await states.next() == .signedIn)

        fixture.server.version = "2.35.0"
        #expect(await sync.sync(.manual) == .serverTooOld(found: "2.35.0"))
        #expect(await states.next() == .serverTooOld(found: "2.35.0"))
        #expect(try fixture.titles() == ["A"])

        fixture.server.version = "2.37.1"
        #expect(await sync.sync(.manual) == .synced)
        #expect(await states.next() == .signedIn)
    }

    @Test("While the Server is too old, the outbox and the progress fetch don't talk to it")
    func outboxAndProgressStop() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let sync = fixture.librarySync()
        fixture.server.version = "2.30.0"
        _ = await sync.sync(.manual)
        try await fixture.listen("a", from: 0, for: 30)
        let before = fixture.server.requests.count

        #expect(await sync.outbox.send() == .serverTooOld(found: "2.30.0"))
        #expect(await sync.progress.fetch() == .serverTooOld(found: "2.30.0"))
        #expect(
            fixture.server.requests.dropFirst(before).allSatisfy { if case .status = $0 { true } else { false } })
        #expect(try fixture.database.listeningSessions().count == 1)
    }
}

@Suite("Sign-in never leaves a session behind on the Server")
struct SignInLogOutTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let database: AppDatabase

    init() throws {
        server = FakeServer(clock: clock)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    func signIn() -> SignIn {
        SignIn(api: server, tokenStore: tokens, database: database)
    }

    /// The refresh tokens the Server handed out at login that it still accepts.
    func liveRefreshTokens() -> [String] {
        loggedInTokens().filter { server.accepts(refreshToken: $0) }
    }

    func loggedInTokens() -> [String] {
        server.requests.compactMap { if case .logOut(_, let token) = $0 { token } else { nil } }
    }

    @Test("No book Library: the login's refresh token is revoked, and nothing is saved")
    func noBookLibrary() async throws {
        server.libraries = [ServerLibrary(id: "pods", name: "Podcasts", mediaType: .podcast)]

        await #expect(throws: SignInError.noBookLibrary) {
            try await signIn().signIn(address: "abs.example.com", username: "listener", password: "listenerpass")
        }

        let revoked = loggedInTokens()
        #expect(revoked.count == 1)
        #expect(revoked.allSatisfy { !server.accepts(refreshToken: $0) })
        #expect(try tokens.load() == nil)
        #expect(try database.serverIdentity() == nil)
    }

    @Test("The Library list failing after login also revokes the login's refresh token")
    func librariesFail() async throws {
        server.beforeHandling { request throws(ServerAPIError) in
            if case .libraries = request { throw .unexpectedStatus(500) }
        }
        await #expect(throws: SignInError.serverError(500)) {
            try await signIn().signIn(address: "abs.example.com", username: "listener", password: "listenerpass")
        }
        #expect(loggedInTokens().count == 1)
    }

    @Test("Cancelling the Library pick revokes the pending sign-in")
    func cancelChoice() async throws {
        server.libraries = [
            ServerLibrary(id: "one", name: "One", mediaType: .book),
            ServerLibrary(id: "two", name: "Two", mediaType: .book),
        ]
        guard
            case .chooseLibrary(let choice) = try await signIn().signIn(
                address: "abs.example.com", username: "listener", password: "listenerpass")
        else {
            Issue.record("expected a Library pick")
            return
        }

        await signIn().cancel(choice)

        #expect(loggedInTokens().count == 1)
        #expect(liveRefreshTokens().isEmpty)
        #expect(try tokens.load() == nil)
    }
}
