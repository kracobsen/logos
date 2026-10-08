import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// What signing out would remove now: the Downloads and the outbox entries the Server hasn't confirmed.
    public func signOutSummary() throws -> SignOutSummary {
        try pool.read { db in
            let downloads =
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM download WHERE state = 'downloaded'") ?? 0
            let bytes =
                try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT COALESCE(SUM(CASE WHEN isVerified THEN size ELSE receivedBytes END), 0) FROM downloadFile"
                ) ?? 0
            let sessions =
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningSession WHERE sentRevision < revision") ?? 0
            let finished = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM finishedChange") ?? 0
            return SignOutSummary(
                downloadCount: downloads, downloadBytes: bytes, unsentSessionCount: sessions,
                unsentFinishedChangeCount: finished)
        }
    }

    /// The sign-out wipe: deletes every row of every table in one transaction, so the database is left like a fresh
    /// install's (same schema, no data). The identity goes with it, so everything observing it sees signed out.
    ///
    /// The only deliberate exception to "the database is never deleted automatically". Tables are found from the
    /// schema, so a table added later is wiped too.
    public func wipe() throws {
        try pool.write { db in
            // Checked at commit, when every table is empty, so the order of the deletes doesn't matter.
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table'
                    AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                    """)
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
            }
        }
        log.notice("Signed out: the database was wiped")
    }
}
