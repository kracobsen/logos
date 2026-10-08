import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Series tab and Series page")
@MainActor
struct SeriesModelTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let sync: LibrarySync

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let clock = TestClock()
        let server = FakeServer(clock: clock)
        let auth = Auth(
            server: URL(string: "https://abs.example.com")!, api: server, tokenStore: InMemoryTokenStore(),
            clock: clock)
        sync = LibrarySync(database: database, api: server, auth: auth, clock: clock)
        let books = [
            FakeServer.book("The First Light", id: "first"), FakeServer.book("Between Lights", id: "between"),
            FakeServer.book("Second Dawn", id: "second"), FakeServer.book("Crossover", id: "crossover"),
        ]
        func saga(_ sequence: String?) -> SeriesMembership {
            SeriesMembership(seriesID: "saga", name: "Fixture Saga", sequence: sequence)
        }
        let series: [String: [SeriesMembership]] = [
            "first": [saga("1")], "between": [saga("1.5")], "second": [saga("2")],
            "crossover": [SeriesMembership(seriesID: "a-other", name: "Another Cycle", sequence: "3")],
        ]
        try database.applyLibraryList(books, syncedAt: .now)
        try database.applyBookData(
            books.map { BookData(book: $0, chapters: [], tracks: [], series: series[$0.id] ?? []) })
    }

    func finish(_ id: String) throws {
        try database.saveProgress(BookProgress(bookID: id, position: 0, lastChanged: .now, isFinished: true))
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The Series tab lists every Series A–Z at once")
    func list() {
        let model = SeriesListModel(database: database)

        #expect(model.series.map(\.name) == ["Another Cycle", "Fixture Saga"])
        #expect(model.series.map(\.bookCount) == [1, 3])
    }

    @Test("A signed-in launch has the Series tab with its Series; a signed-out one has none")
    func launch() throws {
        let sync = self.sync
        #expect(LaunchModel(database: database, makeLibrarySync: { _ in sync }).series == nil)

        try database.saveServerIdentity(
            ServerIdentity(
                serverURL: URL(string: "https://abs.example.com")!, userID: "u", username: "listener",
                libraryID: "library-books", libraryName: "Audiobooks"))

        #expect(LaunchModel(database: database, makeLibrarySync: { _ in sync }).series?.series.count == 2)
    }

    @Test("The Series page shows the reading order with sequences as given, and the Continue button")
    func page() throws {
        try finish("first")

        let model = SeriesPageModel(seriesID: "saga", name: "Fixture Saga", database: database, sync: sync)

        #expect(model.name == "Fixture Saga")
        #expect(model.books.map(\.sequence) == ["1", "1.5", "2"])
        #expect(model.continueTarget?.book.id == "between")
        #expect(model.continueTarget?.label == "Download Book 1.5 to continue")
    }

    @Test("Until Downloads and Playback wire it, the Continue button opens the target Book")
    func continueOpensTheBook() throws {
        try finish("first")
        let model = SeriesPageModel(seriesID: "saga", name: "Fixture Saga", database: database, sync: sync)

        #expect(model.continueTapped() == "between")
        #expect(model.detail(for: "between").detail?.title == "Between Lights")
    }

    @Test("Everything Finished: no button")
    func allFinished() throws {
        for id in ["first", "between", "second"] { try finish(id) }

        let model = SeriesPageModel(seriesID: "saga", name: "Fixture Saga", database: database, sync: sync)

        #expect(model.continueTarget == nil)
        #expect(model.continueTapped() == nil)
    }

    @Test("The page follows the Store: finishing a Book moves the button on")
    func follows() async throws {
        let model = SeriesPageModel(seriesID: "saga", name: "Fixture Saga", database: database, sync: sync)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        #expect(model.continueTarget?.book.id == "first")

        try finish("first")

        await eventually { model.continueTarget?.book.id == "between" }
        #expect(model.continueTarget?.book.id == "between")
    }

    @Test("A Book detail's Series link opens that Series' page")
    func fromBookDetail() {
        let detail = BookDetailModel(bookID: "second", database: database, sync: sync)
        let link = detail.seriesLinks[0]

        let page = detail.seriesPage(for: link)

        #expect(page.name == "Fixture Saga")
        #expect(page.books.map(\.id) == ["first", "between", "second"])
    }

    @Test("A Series that's gone keeps its name and shows no Books")
    func unknown() {
        let model = SeriesPageModel(seriesID: "gone", name: "Gone Saga", database: database, sync: sync)

        #expect(model.name == "Gone Saga")
        #expect(model.books.isEmpty)
        #expect(model.continueTarget == nil)
    }
}
