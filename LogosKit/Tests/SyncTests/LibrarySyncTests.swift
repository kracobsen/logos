import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

/// A signed-in Logos against a scripted Server: what every Sync test starts from.
struct SignedInFixture {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let auth: Auth

    init(books: [ListedBook] = []) async throws {
        server = FakeServer(clock: clock)
        server.books = books
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        _ = try await SignIn(api: server, tokenStore: tokens, database: database)
            .signIn(address: "abs.example.com", username: "listener", password: "listenerpass")
        auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
    }

    func librarySync() -> LibrarySync {
        LibrarySync(database: database, api: server, auth: auth, clock: clock)
    }

    func titles() throws -> Set<String> {
        try Set(database.libraryRows().map(\.title))
    }

    var listRequests: Int {
        server.requests.filter { if case .books = $0 { true } else { false } }.count
    }

    var statusRequests: Int {
        server.requests.filter { if case .status = $0 { true } else { false } }.count
    }
}

@Suite("Library sync, stage 1")
struct LibrarySyncTests {
    @Test("A sync applies the Server's list to the Store, with the time it happened")
    func applies() async throws {
        let fixture = try await SignedInFixture(books: [
            FakeServer.book("Second Dawn"), FakeServer.book("Plain Silence"),
        ])

        let outcome = await fixture.librarySync().sync(.launch)

        #expect(outcome == .synced)
        #expect(try fixture.titles() == ["Second Dawn", "Plain Silence"])
        #expect(try fixture.database.lastLibrarySync() == fixture.clock.now)
    }

    @Test("It asks for the signed-in Library's list, with an access token")
    func asksForTheLibrary() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        _ = await fixture.librarySync().sync(.launch)
        let list = fixture.server.requests.first { if case .books = $0 { true } else { false } }
        guard case .books(let url, let libraryID, let token) = list else {
            Issue.record("expected a list request, got \(fixture.server.requests)")
            return
        }
        #expect(url == fixture.server.address)
        #expect(libraryID == "library-books")
        #expect(token == (try fixture.tokens.load())?.accessToken)
    }

    @Test("A Book the Server no longer lists is deleted; changed Books are updated")
    func removesAndUpdates() async throws {
        let fixture = try await SignedInFixture(books: [
            FakeServer.book("Stays", id: "1"), FakeServer.book("Goes", id: "2"),
        ])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        fixture.server.books = [FakeServer.book("Stays, renamed", id: "1", updatedAt: 1_800_000_000_000)]
        #expect(await sync.sync(.manual) == .synced)

        #expect(try fixture.titles() == ["Stays, renamed"])
    }

    @Test("An empty list is never applied")
    func emptyListNotApplied() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("Kept")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        let lastSync = try fixture.database.lastLibrarySync()
        await fixture.clock.advance(by: .seconds(60))

        fixture.server.books = []
        #expect(await sync.sync(.manual) == .failed)

        #expect(try fixture.titles() == ["Kept"])
        #expect(try fixture.database.lastLibrarySync() == lastSync)
    }

    @Test(
        "A failed or undecodable list is never applied",
        arguments: [ServerAPIError.unreadableResponse, .unexpectedStatus(500), .unexpectedStatus(404)]
    )
    func failedListNotApplied(error: ServerAPIError) async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("Kept")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        fixture.server.books = [FakeServer.book("Other")]
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .books = request { throw error }
        }
        #expect(await sync.sync(.manual) == .failed)

        #expect(try fixture.titles() == ["Kept"])
    }

    @Test("When the Server can't be reached, the sync fails quietly and changes nothing")
    func unreachable() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("Kept")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        fixture.server.isReachable = { _ in false }
        #expect(await sync.sync(.manual) == .unreachable)

        #expect(try fixture.titles() == ["Kept"])
    }

    @Test("Every sync rechecks the Server version first")
    func rechecksVersion() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        let sync = fixture.librarySync()
        let before = fixture.statusRequests

        _ = await sync.sync(.launch)
        _ = await sync.sync(.manual)

        #expect(fixture.statusRequests == before + 2)
    }

    @Test("A Server below 2.36 stops the sync before the list is asked for, saying the version found")
    func stopsBelowMinimum() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("Kept")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        let lists = fixture.listRequests

        fixture.server.version = "2.35.0"
        fixture.server.books = [FakeServer.book("Other")]
        #expect(await sync.sync(.manual) == .serverTooOld(found: "2.35.0"))

        #expect(fixture.listRequests == lists)
        #expect(try fixture.titles() == ["Kept"])
    }

    @Test("Returning to the foreground syncs only if the last successful sync was more than 15 minutes ago")
    func foregroundAfter15Minutes() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        let lists = fixture.listRequests

        await fixture.clock.advance(by: .seconds(14 * 60))
        #expect(await sync.sync(.foreground) == .notNeeded)
        #expect(fixture.listRequests == lists)

        await fixture.clock.advance(by: .seconds(2 * 60))
        #expect(await sync.sync(.foreground) == .synced)
    }

    @Test("Returning to the foreground syncs when no sync has ever succeeded")
    func foregroundWithoutAnySync() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        #expect(await fixture.librarySync().sync(.foreground) == .synced)
    }

    @Test("A failed sync doesn't count: the next foreground tries again")
    func foregroundAfterFailure() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        await fixture.clock.advance(by: .seconds(16 * 60))
        fixture.server.isReachable = { _ in false }
        #expect(await sync.sync(.foreground) == .unreachable)

        fixture.server.isReachable = { _ in true }
        #expect(await sync.sync(.foreground) == .synced)
    }

    @Test("A manual Refresh always syncs, even right after another sync")
    func manualAlwaysSyncs() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        #expect(await sync.sync(.manual) == .synced)
        #expect(fixture.listRequests == 2)
    }

    @Test("Triggers that arrive while a sync runs share it")
    func concurrentTriggersShare() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One")])
        let gate = AsyncGate()
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .books = request { await gate.wait() }
        }
        let sync = fixture.librarySync()

        async let first = sync.sync(.launch)
        async let second = sync.sync(.manual)
        await fixture.clock.advance(by: .zero)  // lets both reach the Server
        await gate.open()

        #expect(await [first, second] == [.synced, .synced])
        #expect(fixture.listRequests == 1)
    }

    @Test("A sync without a signed-in identity does nothing")
    func signedOut() async throws {
        let clock = TestClock()
        let server = FakeServer(clock: clock)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let auth = Auth(server: server.address, api: server, tokenStore: InMemoryTokenStore(), clock: clock)

        let outcome = await LibrarySync(database: database, api: server, auth: auth, clock: clock).sync(.launch)

        #expect(outcome == .notNeeded)
        #expect(server.requests.isEmpty)
    }

    @Test("When the Server rejects the sign-in, the sync stops and says so")
    func needsSignIn() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("Kept")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        fixture.server.revokeAccessTokens()
        fixture.server.revokeRefreshTokens()
        #expect(await sync.sync(.manual) == .needsSignIn)
        #expect(try fixture.titles() == ["Kept"])
    }
}

/// Holds tasks until opened.
actor AsyncGate {
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
