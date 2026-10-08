import Domain
import Foundation
import GRDB
import Testing

@testable import Store

func listedBook(
    _ title: String,
    id: String? = nil,
    authorName: String = "Ada Fixture",
    narratorName: String = "",
    seriesName: String = "",
    updatedAt: Int64 = 1_700_000_000_000
) -> ListedBook {
    ListedBook(
        id: id ?? title,
        mediaID: "media-\(id ?? title)",
        title: title,
        subtitle: nil,
        authorName: authorName,
        authorNameLF: authorName,
        narratorName: narratorName,
        seriesName: seriesName,
        description: "<p>About \(title)</p>",
        publishedYear: "2001",
        genres: ["Fiction"],
        addedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
        updatedAt: updatedAt,
        duration: 3600.5,
        size: 1_000_000,
        hasCover: true
    )
}

@Suite("Library in the Store")
struct LibraryStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("A fresh database has no rows and has never synced")
    func fresh() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        #expect(try database.libraryRows().isEmpty)
        #expect(try database.lastLibrarySync() == nil)
    }

    @Test("An applied list gives one row per Book with its list data, and the time it was synced")
    func applies() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try database.applyLibraryList(
            [
                listedBook("Second Dawn", narratorName: "Nell Narrator", seriesName: "Fixture Saga #2"),
                listedBook("Plain Silence", authorName: "Ben Example"),
            ],
            syncedAt: syncedAt
        )

        let rows = try database.libraryRows().sorted { $0.title < $1.title }
        #expect(
            rows == [
                LibraryRow(
                    id: "Plain Silence",
                    title: "Plain Silence",
                    authorName: "Ben Example",
                    authorNameLF: "Ben Example",
                    narratorName: "",
                    seriesName: "",
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                    duration: 3600.5
                ),
                LibraryRow(
                    id: "Second Dawn",
                    title: "Second Dawn",
                    authorName: "Ada Fixture",
                    authorNameLF: "Ada Fixture",
                    narratorName: "Nell Narrator",
                    seriesName: "Fixture Saga #2",
                    addedAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                    duration: 3600.5
                ),
            ]
        )
        #expect(try database.lastLibrarySync() == syncedAt)
    }

    @Test("Applying again updates changed Books, adds new ones and deletes the ones no longer listed")
    func reapplies() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList([listedBook("Old", id: "1"), listedBook("Gone", id: "2")], syncedAt: .now)

        let removed = try database.applyLibraryList(
            [listedBook("Renamed", id: "1", updatedAt: 1_800_000_000_000), listedBook("New", id: "3")],
            syncedAt: .now
        )

        #expect(try Set(database.libraryRows().map { "\($0.id) \($0.title)" }) == ["1 Renamed", "3 New"])
        #expect(removed.removedBookIDs == ["2"])
    }

    @Test("The Library survives reopening the database, as after a kill or reboot")
    func persists() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_000.5)
        try AppDatabase.open(at: url).applyLibraryList([listedBook("Kept")], syncedAt: syncedAt)

        let reopened = try AppDatabase.open(at: url)
        #expect(try reopened.libraryRows().map(\.title) == ["Kept"])
        #expect(try reopened.lastLibrarySync() == syncedAt)
    }

    @Test("Row and last-sync updates follow each applied list")
    func updates() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        var rows = database.libraryRowUpdates().makeAsyncIterator()
        var lastSync = database.lastLibrarySyncUpdates().makeAsyncIterator()
        #expect(try await rows.next()?.isEmpty == true)
        #expect(try await lastSync.next() == .some(nil))

        let syncedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try database.applyLibraryList([listedBook("Arrived")], syncedAt: syncedAt)

        #expect(try await rows.next()?.map(\.title) == ["Arrived"])
        #expect(try await lastSync.next() == syncedAt)
    }
}

@Suite("Opening the database")
struct DatabaseOpeningTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("It is durable: WAL mode with synchronous=FULL")
    func durable() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        let (journalMode, synchronous) = try database.pool.write { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA synchronous"))
        }
        #expect(journalMode == "wal")
        #expect(synchronous == 2)  // FULL
    }

    @Test("It is included in backups")
    func backedUp() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try AppDatabase.open(at: url)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == false)
    }

    @Test("A file that won't open throws, and the file is kept untouched")
    func unreadableIsKept() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let garbage = Data(repeating: 0xAB, count: 8192)
        try garbage.write(to: url)

        #expect(throws: (any Error).self) { try AppDatabase.open(at: url) }
        #expect(try Data(contentsOf: url) == garbage)
    }

    @Test("A database from the first release migrates and keeps the sign-in")
    func migratesFromV1() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ServerIdentity(
            serverURL: URL(string: "https://abs.example.com")!,
            userID: "user-1",
            username: "listener",
            libraryID: "library-1",
            libraryName: "Audiobooks"
        )
        do {
            let pool = try DatabasePool(path: url.path(percentEncoded: false))
            try AppDatabase.migrator.migrate(pool, upTo: "v1-serverIdentity")
            try AppDatabase(pool: pool).saveServerIdentity(identity)
        }

        let database = try AppDatabase.open(at: url)
        #expect(try database.serverIdentity() == identity)
        try database.applyLibraryList([listedBook("After")], syncedAt: .now)
        #expect(try database.libraryRows().map(\.title) == ["After"])
    }

    @Test("A database from a newer Logos isn't touched: opening fails and the file is kept")
    func newerIsKept() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let database = try AppDatabase.open(at: url)
            try database.pool.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999-from-the-future')")
            }
        }

        #expect(throws: AppDatabase.OpenError.fromNewerVersion) { try AppDatabase.open(at: url) }
        let migrations = try DatabaseQueue(path: url.path(percentEncoded: false)).read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(migrations.contains("v999-from-the-future"))
    }
}
