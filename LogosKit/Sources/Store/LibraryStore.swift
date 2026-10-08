import Domain
import Foundation
import GRDB

/// The list columns of a `book` row: what stage 1 writes. Upserting it leaves the other columns (the later stages'
/// versions and data) as they are.
struct ListedBookRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book"

    var id: String
    var mediaID: String
    var title: String
    var subtitle: String?
    var authorName: String
    var authorNameLF: String
    var narratorName: String
    var seriesName: String
    var description: String?
    var publishedYear: String?
    var genres: [String]
    var addedAt: Int64
    var updatedAt: Int64
    var duration: Double
    var size: Int64
    var hasCover: Bool

    init(_ book: ListedBook) {
        id = book.id
        mediaID = book.mediaID
        title = book.title
        subtitle = book.subtitle
        authorName = book.authorName
        authorNameLF = book.authorNameLF
        narratorName = book.narratorName
        seriesName = book.seriesName
        description = book.description
        publishedYear = book.publishedYear
        genres = book.genres
        addedAt = Int64((book.addedAt.timeIntervalSince1970 * 1000).rounded())
        updatedAt = book.updatedAt
        duration = book.duration
        size = book.size
        hasCover = book.hasCover
    }
}

/// The columns a Library row needs, and nothing more: the Library tab loads every row at launch.
struct LibraryRowRecord: Decodable, FetchableRecord, TableRecord {
    static let databaseTableName = "book"
    static var databaseSelection: [any SQLSelectable] {
        [
            Column("id"), Column("title"), Column("authorName"), Column("narratorName"), Column("seriesName"),
            Column("addedAt"), Column("duration"), Column("authorNameLF"), Column("notOnServer"),
        ]
    }

    var id: String
    var title: String
    var authorName: String
    var narratorName: String
    var seriesName: String
    var addedAt: Int64
    var duration: Double
    var authorNameLF: String
    var notOnServer: Bool

    var row: LibraryRow {
        LibraryRow(
            id: id,
            title: title,
            authorName: authorName,
            authorNameLF: authorNameLF,
            narratorName: narratorName,
            seriesName: seriesName,
            addedAt: Date(timeIntervalSince1970: TimeInterval(addedAt) / 1000),
            duration: duration,
            isNotOnServer: notOnServer
        )
    }
}

/// What applying a Library list changed.
public struct AppliedLibraryList: Sendable, Hashable {
    /// The Books that were deleted because the Server no longer lists them. Downloaded ones are kept as Not on
    /// Server instead, and aren't in here.
    public let removedBookIDs: Set<String>
}

extension AppDatabase {
    /// Applies the Server's full Library list in one transaction: adds and updates every listed Book, deletes the
    /// ones it no longer lists, and records `syncedAt` as the last library sync.
    ///
    /// The caller decides whether a list may be applied at all (never an empty or failed one).
    @discardableResult
    public func applyLibraryList(_ books: [ListedBook], syncedAt: Date) throws -> AppliedLibraryList {
        try pool.write { db in
            let listed = Set(books.map(\.id))
            let stored = try Set(String.fetchAll(db, sql: "SELECT id FROM book"))
            var removed = Set<String>()
            for id in stored.subtracting(listed) where try !Self.keepAsNotOnServer(db, bookID: id) {
                try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [id])
                removed.insert(id)
            }
            for book in books {
                try ListedBookRecord(book).upsert(db)
                try Self.clearNotOnServer(db, bookID: book.id)
            }
            try db.execute(
                sql: """
                    INSERT INTO syncState (id, lastLibrarySync) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET lastLibrarySync = excluded.lastLibrarySync
                    """,
                arguments: [syncedAt.timeIntervalSince1970]
            )
            return AppliedLibraryList(removedBookIDs: removed)
        }
    }

    /// Every Book as a Library row, in no particular order.
    public func libraryRows() throws -> [LibraryRow] {
        try pool.read(Self.fetchLibraryRows)
    }

    /// Every Library row now, then again after each change.
    public func libraryRowUpdates() -> AsyncThrowingStream<[LibraryRow], any Error> {
        observe(Self.fetchLibraryRows)
    }

    /// When a Library list was last applied, or `nil` if never.
    public func lastLibrarySync() throws -> Date? {
        try pool.read(Self.fetchLastLibrarySync)
    }

    /// The last library sync now, then again each time it changes.
    public func lastLibrarySyncUpdates() -> AsyncThrowingStream<Date?, any Error> {
        observe(Self.fetchLastLibrarySync)
    }

    @Sendable static func fetchLibraryRows(_ db: Database) throws -> [LibraryRow] {
        try LibraryRowRecord.fetchAll(db).map(\.row)
    }

    @Sendable static func fetchLastLibrarySync(_ db: Database) throws -> Date? {
        try Double.fetchOne(db, sql: "SELECT lastLibrarySync FROM syncState WHERE id = 1")
            .map(Date.init(timeIntervalSince1970:))
    }
}
