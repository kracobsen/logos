import Domain
import Foundation
import Testing

@testable import Store

@Suite("What Library sort, filter and search read from the Store")
struct LibrarySearchStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    @Test("Library rows carry the author's Last, First name")
    func authorNameLF() throws {
        let book = listedBook("A", authorName: "Ada Fixture")
        let listed = ListedBook(
            id: book.id, mediaID: book.mediaID, title: book.title, subtitle: nil, authorName: "Ada Fixture",
            authorNameLF: "Fixture, Ada", narratorName: "", seriesName: "", description: nil, publishedYear: nil,
            genres: [], addedAt: book.addedAt, updatedAt: book.updatedAt, duration: 1, size: 1, hasCover: false)
        try database.applyLibraryList([listed], syncedAt: .now)

        #expect(try database.libraryRows().map(\.authorNameLF) == ["Fixture, Ada"])
    }

    @Test("Every Book's progress by id, followed as it changes")
    func progressByBook() async throws {
        let first = BookProgress(
            bookID: "a", position: 10, lastChanged: Date(millisecondsSince1970: 1_000), isFinished: false)
        try database.saveProgress(first)
        #expect(try database.progressByBook() == ["a": first])

        var updates = database.progressByBookUpdates().makeAsyncIterator()
        #expect(try await updates.next() == ["a": first])
        let second = BookProgress(
            bookID: "b", position: 0, lastChanged: Date(millisecondsSince1970: 2_000), isFinished: true)
        try database.saveProgress(second)
        #expect(try await updates.next() == ["a": first, "b": second])
    }

    @Test("Series list each Series once, with its Books in reading order (by sequence, unnumbered last)")
    func series() async throws {
        let books = ["Two", "One", "Half", "Loose", "Solo"].map { listedBook($0) }
        try database.applyLibraryList(books, syncedAt: .now)
        func saga(_ sequence: String?) -> SeriesMembership {
            SeriesMembership(seriesID: "saga", name: "Fixture Saga", sequence: sequence)
        }
        try database.applyBookData([
            bookData(books[0], series: [saga("10")]),
            bookData(books[1], series: [saga("2")]),
            bookData(books[2], series: [saga("2.5"), SeriesMembership(seriesID: "x", name: "Extras", sequence: "1")]),
            bookData(books[3], series: [saga(nil)]),
            bookData(books[4]),
        ])

        let series = try database.librarySeries()

        #expect(
            series.sorted { $0.name < $1.name } == [
                LibrarySeries(id: "x", name: "Extras", bookIDs: ["Half"]),
                LibrarySeries(id: "saga", name: "Fixture Saga", bookIDs: ["One", "Half", "Two", "Loose"]),
            ])
        var updates = database.librarySeriesUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.count == 2)
    }
}
