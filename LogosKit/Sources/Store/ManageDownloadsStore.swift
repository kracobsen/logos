import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// Migration `v5-manage-downloads`: the Not on Server flag on Books.
    static func registerManageDownloadsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-manage-downloads") { db in
            // A downloaded Book the Server no longer lists. Its list data, Chapters, tracks and Series stay as they
            // were (no later stage fetches it) until the same id is listed again.
            try db.alter(table: "book") { table in
                table.add(column: "notOnServer", .boolean).notNull().defaults(to: false)
            }
        }
    }

    /// Reorders the queue: the queued Books in `bookIDs` take the queue's queued slots in that order. The active
    /// (downloading) and failed Books keep their places, as do queued Books not in `bookIDs`; ids that aren't queued
    /// are ignored.
    public func reorderQueuedDownloads(_ bookIDs: [String]) throws {
        try pool.write { db in
            let queued = try Row.fetchAll(
                db, sql: "SELECT bookID, queuePosition FROM download WHERE state = ? ORDER BY queuePosition",
                arguments: [DownloadState.queued.rawValue])
            let queuedIDs = Set(queued.map { $0["bookID"] as String })
            var seen = Set<String>()
            let moving = bookIDs.filter { queuedIDs.contains($0) && seen.insert($0).inserted }
            // The slots the moving Books hold now, in queue order, handed out in the new order.
            let slots = queued.filter { seen.contains($0["bookID"]) }.map { $0["queuePosition"] as Int }
            for (bookID, slot) in zip(moving, slots) {
                try db.execute(
                    sql: "UPDATE download SET queuePosition = ? WHERE bookID = ?", arguments: [slot, bookID])
            }
        }
    }

    /// Removes the Book's Download (its rows, not the files on disk). A Not on Server Book goes entirely, with its
    /// progress: returns `true` then, and the caller deletes its cover.
    public func discardDownload(ofBook bookID: String) throws -> Bool {
        try pool.write { db in
            try Self.discardDownload(db, bookID: bookID)
        }
    }

    /// Deletes the Download's rows, and the Book with its progress and held outbox entries if it's Not on Server (then
    /// `true`).
    static func discardDownload(_ db: Database, bookID: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM download WHERE bookID = ?", arguments: [bookID])
        guard try Bool.fetchOne(db, sql: "SELECT notOnServer FROM book WHERE id = ?", arguments: [bookID]) == true
        else { return false }
        try db.execute(sql: "DELETE FROM book WHERE id = ?", arguments: [bookID])
        try db.execute(sql: "DELETE FROM progress WHERE bookID = ?", arguments: [bookID])
        try deleteListeningSessions(db, bookID: bookID)
        return true
    }

    /// Stage 1 for a Book the Server no longer lists: a downloaded one is kept and flagged Not on Server (`true`);
    /// anything else is the caller's to delete (`false`). A Not on Server Book whose Download was found damaged (it
    /// has none now) is kept too, until the listener removes it.
    static func keepAsNotOnServer(_ db: Database, bookID: String) throws -> Bool {
        let state = try String.fetchOne(db, sql: "SELECT state FROM download WHERE bookID = ?", arguments: [bookID])
        if state == nil,
            try Bool.fetchOne(db, sql: "SELECT notOnServer FROM book WHERE id = ?", arguments: [bookID]) == true
        {
            return true
        }
        guard state == DownloadState.downloaded.rawValue else { return false }
        try db.execute(sql: "UPDATE book SET notOnServer = 1 WHERE id = ? AND NOT notOnServer", arguments: [bookID])
        return true
    }

    /// Stage 1 for a listed Book: it's on the Server (again).
    static func clearNotOnServer(_ db: Database, bookID: String) throws {
        try db.execute(sql: "UPDATE book SET notOnServer = 0 WHERE id = ? AND notOnServer", arguments: [bookID])
    }
}
