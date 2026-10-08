import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Library tab")
@MainActor
struct LibraryModelTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() async throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        _ = try await SignIn(api: server, tokenStore: tokens, database: database)
            .signIn(address: "abs.example.com", username: "listener", password: "listenerpass")
    }

    func model() -> LibraryModel {
        let auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
        return LibraryModel(
            database: database,
            sync: LibrarySync(database: database, api: server, auth: auth, clock: clock)
        )
    }

    /// Waits for the model to follow a database change.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Rows already in the Store show at once, A–Z ignoring a leading article, grouped by letter")
    func showsStoredRowsAtOnce() throws {
        try database.applyLibraryList(
            [FakeServer.book("The Long Dark"), FakeServer.book("Between Lights"), FakeServer.book("Loose Parts")],
            syncedAt: clock.now
        )

        let model = model()

        #expect(model.sections.map(\.letter) == ["B", "L"])
        #expect(model.sections.flatMap(\.rows).map(\.title) == ["Between Lights", "The Long Dark", "Loose Parts"])
        #expect(model.lastUpdated == clock.now)
    }

    @Test("A sync on launch fills the Library, and Last updated follows it")
    func launchSyncFills() async throws {
        server.books = [FakeServer.book("Second Dawn"), FakeServer.book("Plain Silence")]
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        #expect(model.sections.isEmpty)
        #expect(model.lastUpdated == nil)

        await model.syncOnLaunch()
        await eventually { model.rowCount == 2 }

        #expect(model.sections.flatMap(\.rows).map(\.title) == ["Plain Silence", "Second Dawn"])
        #expect(model.lastUpdated == clock.now)
    }

    @Test("Syncing Library… shows during the first sync only")
    func syncingLibraryDuringFirstSync() async throws {
        server.books = [FakeServer.book("One")]
        let gate = Gate()
        server.beforeHandling { request throws(ServerAPIError) in
            if case .books = request { await gate.wait() }
        }
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        let first = Task { await model.syncOnLaunch() }
        await eventually { model.showsFirstSync }
        #expect(model.showsFirstSync)
        await gate.open()
        await first.value
        await eventually { model.lastUpdated != nil }
        #expect(!model.showsFirstSync)

        await gate.close()
        let later = Task { await model.refresh() }
        await eventually { model.isSyncing }
        #expect(!model.showsFirstSync)
        await gate.open()
        await later.value
    }

    @Test("A manual Refresh briefly says when the Server couldn't be reached")
    func refreshUnreachable() async throws {
        server.isReachable = { _ in false }
        let model = model()

        await model.refresh()
        #expect(model.refreshMessage == "Couldn't reach the Server.")

        model.dismissRefreshMessage()
        #expect(model.refreshMessage == nil)
    }

    @Test("Launch and foreground syncs fail silently")
    func automaticSyncsAreSilent() async throws {
        server.isReachable = { _ in false }
        let model = model()

        await model.syncOnLaunch()
        await model.syncOnForeground()

        #expect(model.refreshMessage == nil)
    }

    @Test("A successful Refresh says nothing")
    func refreshSucceeds() async throws {
        server.books = [FakeServer.book("One")]
        let model = model()
        await model.refresh()
        #expect(model.refreshMessage == nil)
    }
}

/// Holds tasks until opened; can be closed again.
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

    func close() {
        isOpen = false
    }
}
