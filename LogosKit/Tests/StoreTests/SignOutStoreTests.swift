import Domain
import Foundation
import GRDB
import Testing

@testable import Store

@Suite("Signing out: what's lost, and the wipe")
struct SignOutStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every table the schema has. When a migration adds one, add it here *and* make sure the sign-out wipe
    /// empties it (the wipe test below fills every table listed here).
    static let knownTables: Set<String> = [
        "serverIdentity", "book", "syncState", "progress", "chapter", "audioTrack", "bookSeries", "download",
        "downloadFile", "downloadPolicy", "playbackSettings", "listeningSession", "clientDevice", "finishedChange",
    ]

    func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    func track(_ id: String, size: Int64) -> AudioTrack {
        AudioTrack(
            index: 1, ino: "ino-\(id)", relPath: "01.mp3", size: size, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg")
    }

    func downloaded(_ id: String, size: Int64, in database: AppDatabase) throws {
        try database.queueDownload(ofBook: id)
        _ = try database.startNextDownload()
        try database.setDownloadFiles([track(id, size: size)], ofBook: id)
        var file = try #require(try database.downloadFiles(ofBook: id).first)
        file.isVerified = true
        file.receivedBytes = size
        try database.saveDownloadFile(file)
        try database.finishDownload(ofBook: id, at: start)
    }

    /// Puts at least one row in every table a signed-in, listening, downloading install has.
    func fill(_ database: AppDatabase) throws {
        try database.saveServerIdentity(
            ServerIdentity(
                serverURL: URL(string: "https://abs.example.com")!, userID: "user-listener", username: "listener",
                libraryID: "library-books", libraryName: "Audiobooks"))
        let books = ["a", "b", "c"].map { listedBook($0.uppercased(), id: $0) }
        try database.applyLibraryList(books, syncedAt: start)
        try database.applyBookData(
            books.map { book in
                BookData(
                    book: book, chapters: [Chapter(id: 0, start: 0, end: 60, title: "One")],
                    tracks: [track(book.id, size: 1000)],
                    series: [SeriesMembership(seriesID: "saga", name: "Saga", sequence: "1")])
            })
        try downloaded("a", size: 1000, in: database)
        try database.saveProgress(
            BookProgress(bookID: "a", position: 10, lastChanged: start, isFinished: false), listening: true)
        try database.setFinished(true, ofBook: "b", at: start)
        _ = try database.clientDeviceID()
        try database.setAllowsCellularDownloads(true)
        try database.setSkipBack(.sixty)
    }

    func rowCounts(_ database: AppDatabase) throws -> [String: Int] {
        try database.pool.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table'
                    AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    """)
            return try Dictionary(
                uniqueKeysWithValues: tables.map { table in
                    (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0)
                })
        }
    }

    @Test("The schema's tables are the ones the wipe test knows about")
    func schemaIsKnown() throws {
        #expect(Set(try rowCounts(open()).keys) == Self.knownTables)
    }

    @Test("The wipe empties every table, leaving the database like a fresh install's")
    func wipeEmptiesEverything() throws {
        let database = try open()
        try fill(database)
        let before = try rowCounts(database)
        #expect(before.filter { $0.value == 0 }.isEmpty, "the fixture must fill every table: \(before)")

        try database.wipe()

        #expect(try rowCounts(database).allSatisfy { $0.value == 0 })
        #expect(try database.serverIdentity() == nil)
        #expect(try database.downloadPolicy() == .default)
        #expect(try database.playbackSettings() == .default)
        #expect(try database.lastLibrarySync() == nil)
    }

    @Test("The wipe keeps the schema: the database works as a fresh one afterwards")
    func usableAfterWipe() throws {
        let database = try open()
        try fill(database)
        try database.wipe()

        try database.applyLibraryList([listedBook("New", id: "new")], syncedAt: start)
        #expect(try database.libraryRows().map(\.id) == ["new"])
        #expect(try Set(rowCounts(database).keys) == Self.knownTables)
    }

    @Test("Observers hear the identity go away")
    func observersHearSignOut() async throws {
        let database = try open()
        try fill(database)
        var identities = database.serverIdentityUpdates().makeAsyncIterator()
        #expect(try await identities.next() != nil)

        try database.wipe()

        #expect(try await identities.next() == .some(nil))
    }

    @Test("What sign-out would lose: the Downloads (count and space) and what the outbox still holds")
    func summary() throws {
        let database = try open()
        try fill(database)
        try downloaded("c", size: 2500, in: database)
        try database.queueDownload(ofBook: "b")  // queued, nothing on disk yet

        let summary = try database.signOutSummary()

        #expect(summary.downloadCount == 2)
        #expect(summary.downloadBytes == 3500)
        #expect(summary.unsentSessionCount == 1)
        #expect(summary.unsentFinishedChangeCount == 1)
    }

    @Test("A confirmed session still open isn't counted as unsent")
    func confirmedOpenSessionIsSent() throws {
        let database = try open()
        try fill(database)
        let session = try #require(try database.unsentListeningSessions().first)
        try database.confirmListeningSessions([(session.session.id, session.revision)])

        #expect(try database.signOutSummary().unsentSessionCount == 0)
    }
}
