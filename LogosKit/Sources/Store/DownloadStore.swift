import Domain
import Foundation
import GRDB

/// A `downloadFile` row.
struct DownloadFileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "downloadFile"

    var bookID: String
    var relPath: String
    var position: Int
    var size: Int64
    var isVerified: Bool
    var receivedBytes: Int64
    var resumeData: Data?
    var attempts: Int
    var sizeMismatches: Int

    var file: DownloadFile {
        DownloadFile(
            bookID: bookID, relPath: relPath, size: size, isVerified: isVerified, receivedBytes: receivedBytes,
            resumeData: resumeData, attempts: attempts, sizeMismatches: sizeMismatches)
    }
}

extension AppDatabase {
    /// Migration `v4-downloads`: the Download queue (the source of truth for Downloads) and each Download's files.
    static func registerDownloadsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4-downloads") { db in
            // One row per Book with a Download. `queuePosition` orders the queue (FIFO: each new one goes last).
            try db.create(table: "download") { table in
                table.primaryKey("bookID", .text).references("book", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("queuePosition", .integer).notNull()
                table.column("completedAt", .double)  // seconds since 1970
            }
            try db.create(index: "download_queue", on: "download", columns: ["state", "queuePosition"])
            // One row per file, keyed by relPath (the Server's ino can change). `position` keeps play order.
            try db.create(table: "downloadFile") { table in
                table.column("bookID", .text).notNull().references("download", onDelete: .cascade)
                table.column("relPath", .text).notNull()
                table.column("position", .integer).notNull()
                table.column("size", .integer).notNull()
                table.column("isVerified", .boolean).notNull()
                table.column("receivedBytes", .integer).notNull()
                table.column("resumeData", .blob)
                table.column("attempts", .integer).notNull()
                table.column("sizeMismatches", .integer).notNull()
                table.primaryKey(["bookID", "relPath"])
            }
        }
    }

    /// Puts the Book at the end of the Download queue. A Book already queued, downloading or downloaded is left as it
    /// is; a failed one goes to the end again, keeping its verified files.
    public func queueDownload(ofBook bookID: String) throws {
        try pool.write { db in
            let state = try String.fetchOne(db, sql: "SELECT state FROM download WHERE bookID = ?", arguments: [bookID])
            guard state == nil || state == DownloadState.failed.rawValue else { return }
            let next = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(queuePosition), 0) + 1 FROM download") ?? 1
            try db.execute(
                sql: """
                    INSERT INTO download (bookID, state, queuePosition) VALUES (?, ?, ?)
                    ON CONFLICT(bookID) DO UPDATE SET state = excluded.state, queuePosition = excluded.queuePosition
                    """,
                arguments: [bookID, DownloadState.queued.rawValue, next])
        }
    }

    /// The Books waiting or downloading, in queue order.
    public func downloadQueue() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT bookID FROM download WHERE state IN (?, ?) ORDER BY queuePosition",
                arguments: [DownloadState.downloading.rawValue, DownloadState.queued.rawValue])
        }
    }

    /// The active Book: the one downloading, or else the first queued one, which becomes active. `nil` when the
    /// queue is empty.
    public func startNextDownload() throws -> String? {
        try pool.write { db in
            if let active = try String.fetchOne(
                db, sql: "SELECT bookID FROM download WHERE state = ? ORDER BY queuePosition LIMIT 1",
                arguments: [DownloadState.downloading.rawValue])
            {
                return active
            }
            guard
                let next = try String.fetchOne(
                    db, sql: "SELECT bookID FROM download WHERE state = ? ORDER BY queuePosition LIMIT 1",
                    arguments: [DownloadState.queued.rawValue])
            else { return nil }
            try db.execute(
                sql: "UPDATE download SET state = ? WHERE bookID = ?",
                arguments: [DownloadState.downloading.rawValue, next])
            return next
        }
    }

    /// Marks the Book downloaded: every file is verified.
    public func finishDownload(ofBook bookID: String, at date: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE download SET state = ?, completedAt = ? WHERE bookID = ?",
                arguments: [DownloadState.downloaded.rawValue, date.timeIntervalSince1970, bookID])
            try db.execute(sql: "UPDATE downloadFile SET resumeData = NULL WHERE bookID = ?", arguments: [bookID])
        }
    }

    /// Marks the Book failed. Its files and their state are kept.
    public func failDownload(ofBook bookID: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE download SET state = ? WHERE bookID = ?",
                arguments: [DownloadState.failed.rawValue, bookID])
        }
    }

    /// Deletes the Book's Download and its file rows (not the files on disk).
    public func removeDownload(ofBook bookID: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM download WHERE bookID = ?", arguments: [bookID])
        }
    }

    /// Sets the Download's files from the Book's tracks (in play order), keyed by relPath. Files already known keep
    /// their state (a size change resets it); files the tracks no longer list are dropped.
    public func setDownloadFiles(_ tracks: [AudioTrack], ofBook bookID: String) throws {
        try pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM download WHERE bookID = ?", arguments: [bookID]) != nil
            else { return }
            var known: [String: DownloadFileRecord] = [:]
            for record in try DownloadFileRecord.filter(Column("bookID") == bookID).fetchAll(db) {
                known[record.relPath] = record
            }
            try db.execute(sql: "DELETE FROM downloadFile WHERE bookID = ?", arguments: [bookID])
            for (position, track) in tracks.enumerated() {
                var record =
                    known[track.relPath]
                    ?? DownloadFileRecord(
                        bookID: bookID, relPath: track.relPath, position: position, size: track.size,
                        isVerified: false, receivedBytes: 0, resumeData: nil, attempts: 0, sizeMismatches: 0)
                record.position = position
                if record.size != track.size {
                    record.size = track.size
                    record.isVerified = false
                    record.receivedBytes = 0
                    record.resumeData = nil
                }
                try record.insert(db, onConflict: .ignore)
            }
        }
    }

    /// The Download's files in play order.
    public func downloadFiles(ofBook bookID: String) throws -> [DownloadFile] {
        try pool.read { db in
            try DownloadFileRecord.filter(Column("bookID") == bookID).order(Column("position")).fetchAll(db)
                .map(\.file)
        }
    }

    /// Saves one file's state. A file whose Download is gone (cancelled meanwhile) is ignored.
    public func saveDownloadFile(_ file: DownloadFile) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE downloadFile SET size = ?, isVerified = ?, receivedBytes = ?, resumeData = ?, attempts = ?,
                        sizeMismatches = ?
                    WHERE bookID = ? AND relPath = ?
                    """,
                arguments: [
                    file.size, file.isVerified, file.receivedBytes, file.resumeData, file.attempts,
                    file.sizeMismatches, file.bookID, file.relPath,
                ])
        }
    }

    /// The Book's Download, or `nil` if it has none.
    public func downloadStatus(ofBook bookID: String) throws -> DownloadStatus? {
        try pool.read { db in try Self.fetchDownloadStatuses(db, bookID: bookID)[bookID] }
    }

    /// Every Book's Download, keyed by Book id.
    public func downloadStatuses() throws -> [String: DownloadStatus] {
        try pool.read { db in try Self.fetchDownloadStatuses(db, bookID: nil) }
    }

    /// Every Book's Download now, then again after each change.
    public func downloadStatusUpdates() -> AsyncThrowingStream<[String: DownloadStatus], any Error> {
        observe { db in try Self.fetchDownloadStatuses(db, bookID: nil) }
    }

    /// The Downloaded tab's rows.
    public func downloadsList() throws -> DownloadsList {
        try pool.read(Self.fetchDownloadsList)
    }

    /// The Downloaded tab's rows now, then again after each change.
    public func downloadsListUpdates() -> AsyncThrowingStream<DownloadsList, any Error> {
        observe(Self.fetchDownloadsList)
    }

    private static let statusColumns = """
        download.bookID, download.state,
        IFNULL((SELECT SUM(size) FROM downloadFile WHERE downloadFile.bookID = download.bookID), 0) AS totalBytes,
        IFNULL((SELECT SUM(CASE WHEN isVerified THEN size ELSE MIN(receivedBytes, size) END)
            FROM downloadFile WHERE downloadFile.bookID = download.bookID), 0) AS receivedBytes
        """

    static func fetchDownloadStatuses(_ db: Database, bookID: String?) throws -> [String: DownloadStatus] {
        let filter = bookID == nil ? "" : "WHERE download.bookID = ?"
        let rows = try Row.fetchAll(
            db, sql: "SELECT \(statusColumns) FROM download \(filter)",
            arguments: bookID.map { [$0] } ?? [])
        var statuses: [String: DownloadStatus] = [:]
        for row in rows {
            guard let state = DownloadState(rawValue: row["state"]) else { continue }
            let id: String = row["bookID"]
            statuses[id] = DownloadStatus(
                bookID: id, state: state, totalBytes: row["totalBytes"], receivedBytes: row["receivedBytes"])
        }
        return statuses
    }

    @Sendable static func fetchDownloadsList(_ db: Database) throws -> DownloadsList {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(statusColumns), book.title, book.authorName, progress.lastChanged
                FROM download JOIN book ON book.id = download.bookID
                LEFT JOIN progress ON progress.bookID = download.bookID
                ORDER BY download.queuePosition
                """
        )
        var queue: [DownloadRow] = []
        var downloaded: [(row: DownloadRow, lastChanged: Int64, completedOrder: Int)] = []
        for row in rows {
            guard let state = DownloadState(rawValue: row["state"]) else { continue }
            let download = DownloadRow(
                id: row["bookID"], title: row["title"], authorName: row["authorName"], state: state,
                totalBytes: row["totalBytes"], receivedBytes: row["receivedBytes"])
            if state == .downloaded {
                downloaded.append((download, row["lastChanged"] ?? Int64.min, downloaded.count))
            } else {
                queue.append(download)
            }
        }
        // Most recently listened first; never-listened ones last, in the order they were queued.
        let sorted = downloaded.sorted {
            $0.lastChanged != $1.lastChanged ? $0.lastChanged > $1.lastChanged : $0.completedOrder < $1.completedOrder
        }
        return DownloadsList(queue: queue, downloaded: sorted.map(\.row))
    }
}
