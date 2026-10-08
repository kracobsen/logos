import Domain
import Foundation
import Store
import Testing

@Suite("Series in the Store")
struct SeriesStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    func saga(_ sequence: String?) -> SeriesMembership {
        SeriesMembership(seriesID: "saga", name: "Fixture Saga", sequence: sequence)
    }

    func other(_ sequence: String?) -> SeriesMembership {
        SeriesMembership(seriesID: "other", name: "An Other Cycle", sequence: sequence)
    }

    /// Lists the Books and stores their Series membership.
    func store(_ books: [(ListedBook, [SeriesMembership])]) throws {
        try database.applyLibraryList(books.map(\.0), syncedAt: .now)
        try database.applyBookData(books.map { bookData($0.0, series: $0.1) })
    }

    @Test("Series come from the Books' Series membership, A–Z ignoring a leading article, a Book counted in each")
    func list() throws {
        try store([
            (listedBook("First", id: "first"), [saga("1")]),
            (listedBook("Crossover", id: "crossover"), [saga("2"), other("1")]),
            (listedBook("Loner", id: "loner"), []),
            (listedBook("Zed", id: "zed"), [SeriesMembership(seriesID: "z", name: "Zulu", sequence: nil)]),
        ])

        #expect(
            try database.seriesList() == [
                SeriesSummary(id: "saga", name: "Fixture Saga", bookCount: 2),
                SeriesSummary(id: "other", name: "An Other Cycle", bookCount: 1),
                SeriesSummary(id: "z", name: "Zulu", bookCount: 1),
            ])
    }

    @Test("A Series page has its Books in reading order, sequences verbatim, with their progress")
    func page() throws {
        try store([
            (listedBook("Second", id: "second"), [saga("2")]),
            (listedBook("Loose", id: "loose"), [saga(nil)]),
            (listedBook("Halfway", id: "halfway"), [saga("1.50")]),
            (listedBook("Crossover", id: "crossover"), [other("1"), saga("1")]),
        ])
        try database.saveProgress(
            BookProgress(bookID: "crossover", position: 0, lastChanged: .now, isFinished: true))
        try database.saveProgress(
            BookProgress(bookID: "halfway", position: 42.5, lastChanged: .now, isFinished: false))

        let page = try #require(try database.seriesPage(id: "saga"))

        #expect(page.name == "Fixture Saga")
        #expect(page.books.map(\.id) == ["crossover", "halfway", "second", "loose"])
        #expect(page.books.map(\.sequence) == ["1", "1.50", "2", nil])
        #expect(page.books.map(\.position) == [0, 42.5, 0, 0])
        #expect(page.books.map(\.isFinished) == [true, false, false, false])
        #expect(page.books[0].title == "Crossover")
        #expect(page.books[0].publishedYear == "2001")
        #expect(try database.seriesPage(id: "other")?.books.map(\.sequence) == ["1"])
    }

    @Test("A Series page knows which Books are downloaded (complete Downloads only)")
    func downloaded() throws {
        try store([
            (listedBook("One", id: "one"), [saga("1")]),
            (listedBook("Two", id: "two"), [saga("2")]),
            (listedBook("Three", id: "three"), [saga("3")]),
        ])
        try database.queueDownload(ofBook: "one")
        _ = try database.startNextDownload()
        try database.finishDownload(ofBook: "one")
        try database.queueDownload(ofBook: "two")

        let page = try #require(try database.seriesPage(id: "saga"))

        #expect(page.books.map(\.isDownloaded) == [true, false, false])
    }

    @Test("An unknown Series has no page; a Series whose Books all left the Library is gone")
    func gone() throws {
        try store([(listedBook("First", id: "first"), [saga("1")]), (listedBook("Other", id: "o"), [other("1")])])
        #expect(try database.seriesPage(id: "nope") == nil)

        try database.applyLibraryList([listedBook("Other", id: "o")], syncedAt: .now)

        #expect(try database.seriesPage(id: "saga") == nil)
        #expect(try database.seriesList().map(\.id) == ["other"])
    }

    @Test("The Series page follows the Store, e.g. a Book being Finished")
    func pageUpdates() async throws {
        try store([(listedBook("First", id: "first"), [saga("1")])])
        var updates = database.seriesPageUpdates(id: "saga").makeAsyncIterator()
        #expect(try await updates.next()??.books.first?.isFinished == false)

        try database.saveProgress(BookProgress(bookID: "first", position: 0, lastChanged: .now, isFinished: true))

        #expect(try await updates.next()??.books.first?.isFinished == true)
    }

    @Test("The Series list follows the Store")
    func listUpdates() async throws {
        var updates = database.seriesListUpdates().makeAsyncIterator()
        #expect(try await updates.next() == [])

        try store([(listedBook("First", id: "first"), [saga("1")])])

        #expect(try await updates.next()?.map(\.id) == ["saga"])
    }
}
