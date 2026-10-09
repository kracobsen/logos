import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Library sort, filter and search on the Library tab")
@MainActor
struct LibrarySearchModelTests {
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
            database: database, sync: LibrarySync(database: database, api: server, auth: auth, clock: clock))
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func book(_ title: String, id: String, author: String, authorLF: String, series: String = "", added: Double)
        -> ListedBook
    {
        ListedBook(
            id: id, mediaID: "media-\(id)", title: title, subtitle: nil, authorName: author, authorNameLF: authorLF,
            narratorName: "Nell Narrator", seriesName: series, description: nil, publishedYear: nil, genres: [],
            addedAt: Date(timeIntervalSince1970: added), updatedAt: 1_700_000_000_000, duration: 120, size: 1,
            hasCover: false)
    }

    var fixture: [ListedBook] {
        [
            book(
                "The First Light", id: "b1", author: "Ada Fixture", authorLF: "Fixture, Ada",
                series: "Fixture Saga #1", added: 1),
            book(
                "Second Dawn", id: "b2", author: "Ada Fixture", authorLF: "Fixture, Ada",
                series: "Fixture Saga #2", added: 2),
            book("Plain Silence", id: "p", author: "Ben Example", authorLF: "Example, Ben", added: 3),
        ]
    }

    func store() throws {
        try database.applyLibraryList(fixture, syncedAt: clock.now)
        let saga = { (sequence: String) in SeriesMembership(seriesID: "saga", name: "Fixture Saga", sequence: sequence)
        }
        try database.applyBookData([
            BookData(book: fixture[0], chapters: [], tracks: [], series: [saga("1")]),
            BookData(book: fixture[1], chapters: [], tracks: [], series: [saga("2")]),
            BookData(book: fixture[2], chapters: [], tracks: [], series: []),
        ])
    }

    func save(_ id: String, at position: TimeInterval, minutesAgo: Double, finished: Bool = false) throws {
        try database.saveProgress(
            BookProgress(
                bookID: id, position: position,
                lastChanged: Date(
                    millisecondsSince1970: clock.now.addingTimeInterval(-minutesAgo * 60)
                        .millisecondsSince1970),
                isFinished: finished))
    }

    func titles(_ model: LibraryModel) -> [String] {
        model.sections.flatMap(\.rows).map(\.title)
    }

    @Test("Changing the sort reorders the rows, with the index only for Title and Author")
    func sorts() throws {
        try store()
        try save("p", at: 30, minutesAgo: 1)
        try save("b1", at: 10, minutesAgo: 60)
        let model = model()
        #expect(model.sort == .title)
        #expect(titles(model) == ["The First Light", "Plain Silence", "Second Dawn"])
        #expect(model.showsIndex)

        model.sort = .author
        #expect(titles(model) == ["Plain Silence", "The First Light", "Second Dawn"])
        #expect(model.sections.map(\.letter) == ["E", "F"])
        #expect(model.showsIndex)

        model.sort = .recentlyAdded
        #expect(titles(model) == ["Plain Silence", "Second Dawn", "The First Light"])
        #expect(!model.showsIndex)

        model.sort = .recentlyListened
        #expect(titles(model) == ["Plain Silence", "The First Light", "Second Dawn"])
        #expect(!model.showsIndex)
    }

    @Test("Search shows matching Series above matching Books within the filter, and hides the index")
    func searchWithinFilter() throws {
        try store()
        try save("b2", at: 30, minutesAgo: 1)
        let model = model()

        model.searchText = "saga"
        #expect(model.isSearching)
        #expect(model.seriesResults.map(\.name) == ["Fixture Saga"])
        #expect(model.seriesResults.first?.bookIDs == ["b1", "b2"])
        #expect(titles(model) == ["The First Light", "Second Dawn"])
        #expect(!model.showsIndex)

        model.filter = .notStarted
        #expect(titles(model) == ["The First Light"])

        model.filter = .finished
        #expect(model.seriesResults.isEmpty)
        #expect(model.sections.isEmpty)

        model.searchText = ""
        #expect(!model.isSearching)
        #expect(model.seriesResults.isEmpty)
        #expect(model.showsIndex)
    }

    @Test("The filter follows progress changes in the Store")
    func followsProgress() async throws {
        try store()
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        model.filter = .inProgress
        #expect(model.sections.isEmpty)

        try save("b1", at: 30, minutesAgo: 1)
        await eventually { !model.sections.isEmpty }

        #expect(titles(model) == ["The First Light"])
    }

    @Test("A synced Library keeps the current sort and search")
    func followsRows() async throws {
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        model.sort = .recentlyAdded
        model.searchText = "fixture"

        try store()
        await eventually { model.sections.flatMap(\.rows).count == 2 }

        #expect(titles(model) == ["Second Dawn", "The First Light"])
        await eventually { !model.seriesResults.isEmpty }
        #expect(model.seriesResults.map(\.name) == ["Fixture Saga"])
    }

    @Test("A keystroke and a sort change on 3000 Books stay well within budget")
    func large() throws {
        let books = (0..<3000).map { index in
            book(
                "Book \(index) of the Ünusual Kind", id: "book-\(index)", author: "Author \(index % 97)",
                authorLF: "\(index % 97), Author", series: index % 3 == 0 ? "Series \(index % 50) #\(index)" : "",
                added: Double(index))
        }
        try database.applyLibraryList(books, syncedAt: clock.now)
        for index in stride(from: 0, to: 3000, by: 7) {
            try save("book-\(index)", at: 10, minutesAgo: Double(index))
        }
        let model = model()
        model.filter = .notStarted

        let clock = ContinuousClock()
        var keystrokes: [Duration] = []
        for text in ["u", "un", "unu", "unus", "unusual", "unusual k", "unusua", "1", "12", "123"] {
            keystrokes.append(clock.measure { model.searchText = text })
        }
        model.searchText = ""
        var sortChanges: [Duration] = []
        for sort in [LibrarySort.author, .recentlyAdded, .recentlyListened, .title] {
            sortChanges.append(clock.measure { model.sort = sort })
        }

        print("3000 Books, keystrokes: \(keystrokes.sorted()), sort changes: \(sortChanges.sorted())")
        // Debug build on the simulator; the budgets (50 ms / 100 ms) are measured in Release on the iPhone.
        #expect(keystrokes.max()! < .milliseconds(250))
        #expect(sortChanges.max()! < .milliseconds(500))
    }
}
