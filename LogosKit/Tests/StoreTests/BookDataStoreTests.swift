import Domain
import Foundation
import Testing

@testable import Store

func bookData(
    _ book: ListedBook,
    chapters: [Chapter] = [],
    tracks: [AudioTrack] = [],
    series: [SeriesMembership] = []
) -> BookData {
    BookData(book: book, chapters: chapters, tracks: tracks, series: series)
}

@Suite("Full Book data in the Store")
struct BookDataStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    let chapters = [
        Chapter(id: 0, start: 0, end: 40, title: "Dawn"),
        Chapter(id: 1, start: 40, end: 80, title: "Noon"),
    ]
    let tracks = [
        AudioTrack(
            index: 1, ino: "443", relPath: "01.mp3", size: 240_000, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg"),
        AudioTrack(
            index: 2, ino: "444", relPath: "02.mp3", size: 250_000, duration: 60, startOffset: 60,
            mimeType: "audio/mpeg"),
    ]
    let saga = SeriesMembership(seriesID: "series-saga", name: "Fixture Saga", sequence: "1.5")
    let other = SeriesMembership(seriesID: "series-other", name: "Other", sequence: nil)

    @Test("Every newly listed Book is behind on full data; a fetched one no longer is")
    func behind() throws {
        try database.applyLibraryList([listedBook("A"), listedBook("B")], syncedAt: .now)
        #expect(Set(try database.booksBehindOnFullData()) == ["A", "B"])

        try database.applyBookData([bookData(listedBook("A"))])

        #expect(try database.booksBehindOnFullData() == ["B"])
    }

    @Test("A Book whose updatedAt moves on is behind again")
    func behindAfterUpdate() throws {
        try database.applyLibraryList([listedBook("A")], syncedAt: .now)
        try database.applyBookData([bookData(listedBook("A"))])

        try database.applyLibraryList([listedBook("A", updatedAt: 1_800_000_000_000)], syncedAt: .now)

        #expect(try database.booksBehindOnFullData() == ["A"])
    }

    @Test("A changed Series name in the list makes the Book behind, since a Series rename doesn't bump updatedAt")
    func behindAfterSeriesRename() throws {
        try database.applyLibraryList([listedBook("A", seriesName: "Saga #1")], syncedAt: .now)
        try database.applyBookData([bookData(listedBook("A", seriesName: "Saga #1"))])
        try database.applyLibraryList([listedBook("A", seriesName: "Saga #1")], syncedAt: .now)
        #expect(try database.booksBehindOnFullData().isEmpty)

        try database.applyLibraryList([listedBook("A", seriesName: "The Saga #1")], syncedAt: .now)

        #expect(try database.booksBehindOnFullData() == ["A"])
    }

    @Test("Detail gives the list data, Chapters, tracks and Series membership, in order")
    func detail() throws {
        try database.applyLibraryList([listedBook("A", seriesName: "Fixture Saga #1.5, Other")], syncedAt: .now)
        try database.applyBookData([
            bookData(
                listedBook("A", seriesName: "Fixture Saga #1.5, Other"),
                chapters: chapters, tracks: tracks, series: [saga, other])
        ])

        let detail = try #require(try database.bookDetail(id: "A"))

        #expect(detail.title == "A")
        #expect(detail.authorName == "Ada Fixture")
        #expect(detail.description == "<p>About A</p>")
        #expect(detail.duration == 3600.5)
        #expect(detail.size == 1_000_000)
        #expect(detail.chapters.chapters == chapters)
        #expect(detail.tracks == tracks)
        #expect(detail.series == [saga, other])
        #expect(detail.hasCurrentFullData)
    }

    @Test("Before its full data arrives, a Book's detail has its list data, one Chapter and no Series yet")
    func detailBeforeFullData() throws {
        try database.applyLibraryList([listedBook("A")], syncedAt: .now)

        let detail = try #require(try database.bookDetail(id: "A"))

        #expect(detail.title == "A")
        #expect(detail.hasCurrentFullData == false)
        #expect(detail.chapters.count == 1)
        #expect(detail.series.isEmpty)
        #expect(detail.tracks.isEmpty)
    }

    @Test("A Book that isn't in the Store has no detail")
    func noDetail() throws {
        #expect(try database.bookDetail(id: "missing") == nil)
    }

    @Test("Fetching again replaces the Chapters, tracks and Series, and refreshes the list data")
    func replaces() throws {
        try database.applyLibraryList([listedBook("A")], syncedAt: .now)
        try database.applyBookData([bookData(listedBook("A"), chapters: chapters, tracks: tracks, series: [saga])])
        try database.applyLibraryList([listedBook("A", updatedAt: 1_800_000_000_000)], syncedAt: .now)

        try database.applyBookData([
            bookData(
                listedBook("A, revised", id: "A", updatedAt: 1_800_000_000_000), chapters: [chapters[0]],
                tracks: [tracks[0]], series: [])
        ])

        let detail = try #require(try database.bookDetail(id: "A"))
        #expect(detail.title == "A, revised")
        #expect(detail.chapters.chapters == [chapters[0]])
        #expect(detail.tracks == [tracks[0]])
        #expect(detail.series.isEmpty)
        #expect(detail.hasCurrentFullData)
        #expect(try database.booksBehindOnFullData().isEmpty)
    }

    @Test("Full data for a Book the list has removed is dropped, never bringing the Book back")
    func removedBook() throws {
        try database.applyLibraryList([listedBook("A")], syncedAt: .now)

        try database.applyBookData([bookData(listedBook("Gone"), chapters: chapters)])

        #expect(try database.bookDetail(id: "Gone") == nil)
        #expect(try database.libraryRows().map(\.title) == ["A"])
    }

    @Test("Full data older than the Book's list data is ignored")
    func olderData() throws {
        try database.applyLibraryList([listedBook("A", updatedAt: 1_800_000_000_000)], syncedAt: .now)

        try database.applyBookData([bookData(listedBook("Old title", id: "A"), chapters: chapters)])

        let detail = try #require(try database.bookDetail(id: "A"))
        #expect(detail.title == "A")
        #expect(detail.hasCurrentFullData == false)
        #expect(try database.booksBehindOnFullData() == ["A"])
    }

    @Test("Removing a Book from the list removes its Chapters, tracks and Series too")
    func cascade() throws {
        try database.applyLibraryList([listedBook("A"), listedBook("B")], syncedAt: .now)
        try database.applyBookData([bookData(listedBook("A"), chapters: chapters, tracks: tracks, series: [saga])])

        try database.applyLibraryList([listedBook("B")], syncedAt: .now)

        let leftovers = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT (SELECT COUNT(*) FROM chapter) + (SELECT COUNT(*) FROM audioTrack)
                        + (SELECT COUNT(*) FROM bookSeries)
                    """)
        }
        #expect(leftovers == 0)
    }

    @Test("Detail updates follow the database")
    func detailUpdates() async throws {
        try database.applyLibraryList([listedBook("A")], syncedAt: .now)
        var updates = database.bookDetailUpdates(id: "A").makeAsyncIterator()
        let first = try await updates.next()
        #expect(first??.hasCurrentFullData == false)

        try database.applyBookData([bookData(listedBook("A"), chapters: chapters)])

        let second = try await updates.next()
        #expect(second??.chapters.chapters == chapters)
    }
}
