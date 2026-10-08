import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("In Progress tab and Book progress")
@MainActor
struct InProgressModelTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(
            [
                FakeServer.book("Older", id: "older"), FakeServer.book("Newer", id: "newer"),
                FakeServer.book("Done", id: "done"),
            ],
            syncedAt: now
        )
    }

    func save(_ id: String, at position: TimeInterval, minutesAgo: Double, finished: Bool = false) throws {
        try database.saveProgress(
            BookProgress(
                bookID: id, position: position, lastChanged: now.addingTimeInterval(-minutesAgo * 60),
                isFinished: finished))
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Started, unfinished Books show at once, most recently listened first")
    func showsAtOnce() throws {
        try save("older", at: 10, minutesAgo: 60)
        try save("newer", at: 10, minutesAgo: 1)
        try save("done", at: 3600, minutesAgo: 0, finished: true)

        let model = InProgressModel(database: database)

        #expect(model.rows.map(\.title) == ["Newer", "Older"])
    }

    @Test("A signed-in launch has the In Progress tab with its rows; a signed-out one has none")
    func launch() throws {
        try save("older", at: 10, minutesAgo: 60)
        let makeSync = { (identity: ServerIdentity) -> LibrarySync in
            let clock = TestClock()
            let server = FakeServer(clock: clock)
            let auth = Auth(server: identity.serverURL, api: server, tokenStore: InMemoryTokenStore(), clock: clock)
            return LibrarySync(database: database, api: server, auth: auth, clock: clock)
        }
        #expect(LaunchModel(database: database, makeLibrarySync: makeSync).inProgress == nil)

        try database.saveServerIdentity(
            ServerIdentity(
                serverURL: URL(string: "https://abs.example.com")!, userID: "u", username: "listener",
                libraryID: "library-books", libraryName: "Audiobooks"))

        #expect(LaunchModel(database: database, makeLibrarySync: makeSync).inProgress?.rows.map(\.id) == ["older"])
    }

    @Test("The list follows the Store, e.g. after a fetch moves a Book to the top or finishes it")
    func follows() async throws {
        try save("older", at: 10, minutesAgo: 60)
        try save("newer", at: 10, minutesAgo: 1)
        let model = InProgressModel(database: database)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        try database.applyFetchedProgress([
            FetchedProgress(bookID: "older", position: 500, isFinished: false, lastUpdate: now.millisecondsSince1970),
            FetchedProgress(bookID: "newer", position: 3600, isFinished: true, lastUpdate: now.millisecondsSince1970),
        ])
        await eventually { model.rows.map(\.id) == ["older"] }

        #expect(model.rows.map(\.id) == ["older"])
        #expect(model.rows.first?.position == 500)
    }

    @Test(
        "A Book's progress reads as not started, how far in and how much is left, or Finished",
        arguments: [
            (nil, BookProgressStatus.notStarted),
            (BookProgress(bookID: "b", position: 0, lastChanged: .distantPast, isFinished: false), .notStarted),
            (
                BookProgress(bookID: "b", position: 900, lastChanged: .distantPast, isFinished: false),
                .inProgress(fraction: 0.25, remaining: 2700)
            ),
            (BookProgress(bookID: "b", position: 3600, lastChanged: .distantPast, isFinished: true), .finished),
        ] as [(BookProgress?, BookProgressStatus)]
    )
    func status(progress: BookProgress?, expected: BookProgressStatus) {
        #expect(BookProgressStatus(progress, duration: 3600) == expected)
    }

    @Test("Book detail's progress shows at once and follows changes")
    func bookProgress() async throws {
        try save("older", at: 900, minutesAgo: 60)
        let model = BookProgressModel(database: database, bookID: "older", duration: 3600)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        #expect(model.status == .inProgress(fraction: 0.25, remaining: 2700))

        try save("older", at: 3600, minutesAgo: 0, finished: true)
        await eventually { model.status == .finished }

        #expect(model.status == .finished)
    }
}
