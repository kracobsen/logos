import Domain
import Foundation
import GRDB

/// A `finishedChange` row: a Book's Finished change waiting to reach the Server. One per Book at most; a later change
/// replaces it. Not a foreign key to `book`, like progress: a Not on Server Book's change is held, not lost.
struct FinishedChangeRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "finishedChange"

    var bookID: String
    var isFinished: Bool
    var position: Double
    var lastUpdate: Int64  // ms since 1970, when the listener acted

    init(_ change: FinishedChange) {
        bookID = change.bookID
        isFinished = change.isFinished
        position = change.position
        lastUpdate = change.lastUpdate.millisecondsSince1970
    }

    var change: FinishedChange {
        FinishedChange(
            bookID: bookID, isFinished: isFinished, position: position,
            lastUpdate: Date(millisecondsSince1970: lastUpdate))
    }
}

extension AppDatabase {
    /// Migration `v6-finished-changes`: the Finished changes in the outbox.
    static func registerFinishedChangesMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-finished-changes") { db in
            try db.create(table: "finishedChange") { table in
                table.primaryKey("bookID", .text)
                table.column("isFinished", .boolean).notNull()
                table.column("position", .double).notNull()
                table.column("lastUpdate", .integer).notNull()
            }
        }
    }

    /// Writes a local progress change (a Player write or Finished by hand), and queues a Finished change when it
    /// changes the Book's Finished state. Fetched progress doesn't come through here: it's the Server's already.
    static func writeLocalProgress(_ progress: BookProgress, _ db: Database) throws {
        let wasFinished =
            try Bool.fetchOne(db, sql: "SELECT isFinished FROM progress WHERE bookID = ?", arguments: [progress.bookID])
            ?? false
        try ProgressRecord(progress).upsert(db)
        guard progress.isFinished != wasFinished else { return }
        let change = FinishedChange(
            bookID: progress.bookID, isFinished: progress.isFinished, position: progress.position,
            lastUpdate: Date(millisecondsSince1970: progress.lastChanged.millisecondsSince1970))
        try FinishedChangeRecord(change).upsert(db)
    }

    /// The Finished changes to send, by Book id: those whose Book is in the Library and on the Server. A Not on
    /// Server Book's change (or one the Library no longer has) is held: kept, not sent.
    public func pendingFinishedChanges() throws -> [PendingFinishedChange] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT finishedChange.*, book.duration AS bookDuration
                    FROM finishedChange JOIN book ON book.id = finishedChange.bookID
                    WHERE NOT book.notOnServer
                    ORDER BY finishedChange.bookID
                    """
            ).map { row in
                PendingFinishedChange(change: try FinishedChangeRecord(row: row).change, duration: row["bookDuration"])
            }
        }
    }

    /// Every Finished change in the outbox (held ones too) now, then again after each change.
    public func pendingFinishedChangeUpdates() -> AsyncThrowingStream<[FinishedChange], any Error> {
        observe { db in try FinishedChangeRecord.order(Column("bookID")).fetchAll(db).map(\.change) }
    }

    /// The Server has `change` (or already had it): it leaves the outbox, unless the Book changed again since.
    public func confirmFinishedChange(_ change: FinishedChange) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM finishedChange WHERE bookID = ? AND isFinished = ? AND lastUpdate = ?",
                arguments: [change.bookID, change.isFinished, change.lastUpdate.millisecondsSince1970])
        }
    }

    /// Drops the Finished changes the Server's progress overrules (``FinishedChanges/isOverruled(_:by:)``): a
    /// change made elsewhere after the listener acted. Returns their Book ids. Applying `records` afterwards then
    /// takes the Server's state for them (unless they still have unsent sessions).
    @discardableResult
    public func dropFinishedChanges(overruledBy records: [FetchedProgress]) throws -> Set<String> {
        let server = Dictionary(records.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        return try pool.write { db in
            var dropped: Set<String> = []
            for record in try FinishedChangeRecord.fetchAll(db)
            where FinishedChanges.isOverruled(record.change, by: server[record.bookID]) {
                try record.delete(db)
                dropped.insert(record.bookID)
            }
            return dropped
        }
    }

    static func bookIDsWithPendingFinishedChanges(_ db: Database) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: "SELECT bookID FROM finishedChange"))
    }

    /// Deletes a Book's Finished change (with the Book itself, when its Download is removed while Not on Server).
    static func deleteFinishedChange(_ db: Database, bookID: String) throws {
        try db.execute(sql: "DELETE FROM finishedChange WHERE bookID = ?", arguments: [bookID])
    }
}
