import Domain
import Foundation
import Store
import Testing

@Suite("Cover versions in the Store")
struct CoverStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    @Test("Every newly listed Book's cover is behind, at its updatedAt")
    func newBooksAreBehind() throws {
        let database = try open()
        var noCover = listedBook("No cover", updatedAt: 7)
        noCover = ListedBook(copying: noCover, hasCover: false)
        try database.applyLibraryList([listedBook("One", updatedAt: 5), noCover], syncedAt: now)

        #expect(
            Set(try database.coversBehind()) == [
                CoverToFetch(bookID: "One", version: 5, hasCover: true),
                CoverToFetch(bookID: "No cover", version: 7, hasCover: false),
            ]
        )
    }

    @Test("A cover set at the Book's updatedAt is up to date until updatedAt changes")
    func upToDateUntilUpdated() throws {
        let database = try open()
        try database.applyLibraryList([listedBook("One", updatedAt: 5)], syncedAt: now)
        try database.setCoverVersion(5, forBook: "One")
        #expect(try database.coversBehind().isEmpty)

        try database.applyLibraryList([listedBook("One", updatedAt: 6)], syncedAt: now)
        #expect(try database.coversBehind() == [CoverToFetch(bookID: "One", version: 6, hasCover: true)])
    }

    @Test("Setting the version of a Book that's gone does nothing")
    func goneBook() throws {
        let database = try open()
        try database.setCoverVersion(5, forBook: "Gone")
        #expect(try database.coversBehind().isEmpty)
    }

    @Test("The file check resets the version of a cover whose file is missing, and deletes files with no Book")
    func fileCheck() throws {
        let database = try open()
        let covers = try CoverFiles(directory: directory.appending(path: "Covers"))
        try database.applyLibraryList(
            [listedBook("Kept", updatedAt: 1), listedBook("Lost", updatedAt: 2)], syncedAt: now)
        for (id, version) in [("Kept", Int64(1)), ("Lost", 2)] {
            try covers.save(Data("jpeg".utf8), forBook: id)
            try database.setCoverVersion(version, forBook: id)
        }
        try covers.save(Data("jpeg".utf8), forBook: "Orphan")
        covers.delete(forBook: "Lost")

        try database.checkCoverFiles(covers)

        #expect(try database.coversBehind() == [CoverToFetch(bookID: "Lost", version: 2, hasCover: true)])
        #expect(covers.exists(forBook: "Kept"))
        #expect(!covers.exists(forBook: "Orphan"))
    }

    @Test("The file check leaves Books without a cover alone")
    func fileCheckNoCover() throws {
        let database = try open()
        let covers = try CoverFiles(directory: directory.appending(path: "Covers"))
        try database.applyLibraryList(
            [ListedBook(copying: listedBook("Bare", updatedAt: 3), hasCover: false)], syncedAt: now)
        try database.setCoverVersion(3, forBook: "Bare")

        try database.checkCoverFiles(covers)

        #expect(try database.coversBehind().isEmpty)
    }

    @Test("The cover versions of Books with a cover, now and after each change")
    func versionUpdates() async throws {
        let database = try open()
        try database.applyLibraryList([listedBook("One", updatedAt: 5)], syncedAt: now)
        var updates = database.coverVersionUpdates().makeAsyncIterator()
        #expect(try await updates.next() == [:])

        try database.setCoverVersion(5, forBook: "One")
        #expect(try await updates.next() == ["One": 5])
    }
}

extension ListedBook {
    init(copying book: ListedBook, hasCover: Bool) {
        self.init(
            id: book.id, mediaID: book.mediaID, title: book.title, subtitle: book.subtitle,
            authorName: book.authorName, authorNameLF: book.authorNameLF, narratorName: book.narratorName,
            seriesName: book.seriesName, description: book.description, publishedYear: book.publishedYear,
            genres: book.genres, addedAt: book.addedAt, updatedAt: book.updatedAt, duration: book.duration,
            size: book.size, hasCover: hasCover)
    }
}
