import Domain
import Foundation
import GRDB

/// A `progress` row: one Book's progress.
///
/// Deliberately not a foreign key to `book`: local progress is never deleted because the Server lacks it, so it
/// outlives its Book leaving the Library and is there again if the same id comes back.
struct ProgressRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "progress"

    var bookID: String
    var position: Double
    var lastChanged: Int64  // ms since 1970, when the user acted
    var isFinished: Bool

    init(_ progress: BookProgress) {
        bookID = progress.bookID
        position = progress.position
        lastChanged = progress.lastChanged.millisecondsSince1970
        isFinished = progress.isFinished
    }

    var progress: BookProgress {
        BookProgress(
            bookID: bookID,
            position: position,
            lastChanged: Date(millisecondsSince1970: lastChanged),
            isFinished: isFinished
        )
    }

    /// Migration `v3-progress`.
    static func createTable(_ db: Database) throws {
        try db.create(table: "progress") { table in
            table.primaryKey("bookID", .text)
            table.column("position", .double).notNull()
            table.column("lastChanged", .integer).notNull()
            table.column("isFinished", .boolean).notNull()
        }
        try db.create(index: "progress_lastChanged", on: "progress", columns: ["lastChanged"])
    }
}

/// What applying fetched progress changed.
public struct AppliedProgress: Sendable, Hashable {
    /// The Books whose progress the fetch replaced.
    public let changedBookIDs: Set<String>
}

extension AppDatabase {
    /// Saves one Book's progress, replacing what was there.
    public func saveProgress(_ progress: BookProgress) throws {
        try pool.write { db in try ProgressRecord(progress).upsert(db) }
    }

    /// The Book's progress, or `nil` if it has none.
    public func progress(ofBook bookID: String) throws -> BookProgress? {
        try pool.read { db in try Self.fetchProgress(db, bookID: bookID) }
    }

    /// The Book's progress now, then again after each change.
    public func progressUpdates(ofBook bookID: String) -> AsyncThrowingStream<BookProgress?, any Error> {
        observe { db in try Self.fetchProgress(db, bookID: bookID) }
    }

    /// Applies progress fetched from the Server in one transaction, by ``ProgressMerge``: last-writer-wins on when the
    /// user acted, and only real changes are written. Records for Books not in the Library are ignored. Nothing is
    /// ever deleted.
    @discardableResult
    public func applyFetchedProgress(_ records: [FetchedProgress]) throws -> AppliedProgress {
        try pool.write { db in
            let books = try Set(String.fetchAll(db, sql: "SELECT id FROM book"))
            var local: [String: BookProgress] = [:]
            for record in try ProgressRecord.fetchAll(db) {
                local[record.bookID] = record.progress
            }
            var changed: Set<String> = []
            for fetched in records where books.contains(fetched.bookID) {
                guard let adopted = ProgressMerge.adopting(fetched, over: local[fetched.bookID]) else { continue }
                try ProgressRecord(adopted).upsert(db)
                local[fetched.bookID] = adopted
                changed.insert(fetched.bookID)
            }
            return AppliedProgress(changedBookIDs: changed)
        }
    }

    /// The In Progress Books in the Library (started, not Finished), most recently changed first.
    public func inProgressRows() throws -> [InProgressRow] {
        try pool.read(Self.fetchInProgressRows)
    }

    /// The In Progress rows now, then again after each change.
    public func inProgressRowUpdates() -> AsyncThrowingStream<[InProgressRow], any Error> {
        observe(Self.fetchInProgressRows)
    }

    static func fetchProgress(_ db: Database, bookID: String) throws -> BookProgress? {
        try ProgressRecord.fetchOne(db, key: bookID)?.progress
    }

    @Sendable static func fetchInProgressRows(_ db: Database) throws -> [InProgressRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT book.id, book.title, book.authorName, book.duration, progress.position, progress.lastChanged
                FROM progress JOIN book ON book.id = progress.bookID
                WHERE progress.isFinished = 0 AND progress.position > 0
                ORDER BY progress.lastChanged DESC, book.id
                """
        ).map { row in
            InProgressRow(
                id: row["id"],
                title: row["title"],
                authorName: row["authorName"],
                duration: row["duration"],
                position: row["position"],
                lastChanged: Date(millisecondsSince1970: row["lastChanged"])
            )
        }
    }
}
