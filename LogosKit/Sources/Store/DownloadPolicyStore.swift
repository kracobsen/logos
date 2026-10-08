import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// Migration `v5-download-policy`: the Downloads setting and the queue's storage pause, in one row.
    static func registerDownloadPolicyMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5-download-policy") { db in
            // One row at most (id is always 1); no row means the defaults.
            try db.create(table: "downloadPolicy") { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("allowsCellular", .boolean).notNull().defaults(to: false)
                table.column("isPausedForStorage", .boolean).notNull().defaults(to: false)
            }
        }
    }

    /// The Downloads setting and the queue's storage pause.
    public func downloadPolicy() throws -> DownloadPolicy {
        try pool.read(Self.fetchDownloadPolicy)
    }

    /// The policy now, then again after each change.
    public func downloadPolicyUpdates() -> AsyncThrowingStream<DownloadPolicy, any Error> {
        observe(Self.fetchDownloadPolicy)
    }

    /// The "Allow downloads over cellular" setting.
    public func setAllowsCellularDownloads(_ allowed: Bool) throws {
        try setPolicyColumn("allowsCellular", to: allowed)
    }

    /// Pauses the queue for lack of storage, or lifts the pause.
    public func setDownloadsPausedForStorage(_ paused: Bool) throws {
        try setPolicyColumn("isPausedForStorage", to: paused)
    }

    /// The Book that would become active next: the first queued one, when none is downloading.
    public func nextDownloadToStart() throws -> String? {
        try pool.read { db in
            let downloading = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM download WHERE state = ?", arguments: [DownloadState.downloading.rawValue])
            guard downloading == nil else { return nil }
            return try String.fetchOne(
                db, sql: "SELECT bookID FROM download WHERE state = ? ORDER BY queuePosition LIMIT 1",
                arguments: [DownloadState.queued.rawValue])
        }
    }

    /// The Book downloading now, if any.
    public func activeDownload() throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT bookID FROM download WHERE state = ? ORDER BY queuePosition LIMIT 1",
                arguments: [DownloadState.downloading.rawValue])
        }
    }

    /// The bytes the Book's Download still has to write: its files that aren't verified, or the whole Book while its
    /// files aren't known yet.
    public func bytesStillNeeded(forBook bookID: String) throws -> Int64 {
        try pool.read { db in
            let files =
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadFile WHERE bookID = ?", arguments: [bookID])
                ?? 0
            if files > 0 {
                return try Int64.fetchOne(
                    db, sql: "SELECT IFNULL(SUM(size), 0) FROM downloadFile WHERE bookID = ? AND NOT isVerified",
                    arguments: [bookID]) ?? 0
            }
            return try Int64.fetchOne(db, sql: "SELECT size FROM book WHERE id = ?", arguments: [bookID]) ?? 0
        }
    }

    private func setPolicyColumn(_ column: String, to value: Bool) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO downloadPolicy (id, \(column)) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET \(column) = excluded.\(column)
                    """,
                arguments: [value])
        }
    }

    @Sendable static func fetchDownloadPolicy(_ db: Database) throws -> DownloadPolicy {
        guard let row = try Row.fetchOne(db, sql: "SELECT allowsCellular, isPausedForStorage FROM downloadPolicy")
        else { return .default }
        return DownloadPolicy(allowsCellular: row["allowsCellular"], isPausedForStorage: row["isPausedForStorage"])
    }
}
