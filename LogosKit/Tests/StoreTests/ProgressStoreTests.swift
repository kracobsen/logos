import Domain
import Foundation
import GRDB
import Testing

@testable import Store

@Suite("Progress in the Store")
struct ProgressStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func progress(_ bookID: String, at position: TimeInterval, minutesAgo: Double, finished: Bool = false)
        -> BookProgress
    {
        BookProgress(
            bookID: bookID,
            position: position,
            lastChanged: now.addingTimeInterval(-minutesAgo * 60),
            isFinished: finished
        )
    }

    @Test("Saved progress survives reopening the database, to the millisecond")
    func persists() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = BookProgress(
            bookID: "a", position: 61.25, lastChanged: Date(timeIntervalSince1970: 1_800_000_000.123),
            isFinished: false)
        try AppDatabase.open(at: url).saveProgress(saved)

        let reopened = try AppDatabase.open(at: url)

        #expect(try reopened.progress(ofBook: "a") == saved)
        #expect(try reopened.progress(ofBook: "b") == nil)
    }

    @Test("In Progress lists started, unfinished Books in the Library, most recently changed first")
    func inProgressRows() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList(
            ["Older", "Newest", "Finished", "Not started", "Untouched"].map { listedBook($0) }, syncedAt: now)
        try database.saveProgress(progress("Older", at: 100, minutesAgo: 60))
        try database.saveProgress(progress("Newest", at: 5, minutesAgo: 1))
        try database.saveProgress(progress("Finished", at: 3600, minutesAgo: 0, finished: true))
        try database.saveProgress(progress("Not started", at: 0, minutesAgo: 0))
        try database.saveProgress(progress("Not in the Library", at: 50, minutesAgo: 0))

        let rows = try database.inProgressRows()

        #expect(rows.map(\.title) == ["Newest", "Older"])
        #expect(
            rows.last
                == InProgressRow(
                    id: "Older", title: "Older", authorName: "Ada Fixture", duration: 3600.5, position: 100,
                    lastChanged: now.addingTimeInterval(-3600))
        )
    }

    @Test("Progress is kept when its Book leaves the Library, and shows again if the Book comes back")
    func keptWhenBookLeaves() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList([listedBook("Goes"), listedBook("Stays")], syncedAt: now)
        try database.saveProgress(progress("Goes", at: 100, minutesAgo: 1))

        try database.applyLibraryList([listedBook("Stays")], syncedAt: now)
        #expect(try database.progress(ofBook: "Goes")?.position == 100)
        #expect(try database.inProgressRows().isEmpty)

        try database.applyLibraryList([listedBook("Goes"), listedBook("Stays")], syncedAt: now)
        #expect(try database.inProgressRows().map(\.id) == ["Goes"])
    }

    @Test("The In Progress rows follow changes")
    func inProgressUpdates() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList([listedBook("One")], syncedAt: now)
        var updates = database.inProgressRowUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.isEmpty == true)

        try database.saveProgress(progress("One", at: 10, minutesAgo: 0))

        #expect(try await updates.next()?.map(\.id) == ["One"])
    }

    @Test("A Book's progress follows changes")
    func bookProgressUpdates() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        var updates = database.progressUpdates(ofBook: "One").makeAsyncIterator()
        #expect(try await updates.next() == .some(nil))

        try database.saveProgress(progress("One", at: 10, minutesAgo: 0))

        #expect(try await updates.next()??.position == 10)
    }

    @Test("A database with a Library migrates to progress, keeping its Books, with no progress yet")
    func migratesFromV2() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let pool = try DatabasePool(path: url.path(percentEncoded: false))
            try AppDatabase.migrator.migrate(pool, upTo: "v2-library")
            try pool.write { db in try ListedBookRecord(listedBook("Kept")).insert(db) }
        }

        let database = try AppDatabase.open(at: url)

        #expect(try database.libraryRows().map(\.title) == ["Kept"])
        #expect(try database.progress(ofBook: "Kept") == nil)
        #expect(try database.inProgressRows().isEmpty)
    }

    @Test("Fetched progress for Books the Library doesn't have is ignored")
    func unknownBooksIgnored() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList([listedBook("Known")], syncedAt: now)

        let applied = try database.applyFetchedProgress([
            FetchedProgress(bookID: "Known", position: 30, isFinished: false, lastUpdate: 1_800_000_000_000),
            FetchedProgress(bookID: "Unknown", position: 30, isFinished: false, lastUpdate: 1_800_000_000_000),
        ])

        #expect(applied.changedBookIDs == ["Known"])
        #expect(try database.progress(ofBook: "Known")?.position == 30)
        #expect(try database.progress(ofBook: "Unknown") == nil)
    }
}
