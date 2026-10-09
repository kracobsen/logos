import Foundation
import GRDB

extension AppDatabase {
    /// Migration `v7-server-too-old`: the version the last sync's check found too old, so Server too old outlives a
    /// relaunch (the launch send and fetch would otherwise reach the Server before the next check).
    static func registerServerTooOldMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7-server-too-old") { db in
            try db.alter(table: "syncState") { table in
                table.add(column: "serverTooOldVersion", .text)
            }
        }
    }

    /// The version the last check found too old, or `nil` if it was supported (or there was no check yet).
    public func serverTooOldVersion() throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT serverTooOldVersion FROM syncState WHERE id = 1")
        }
    }

    /// Records what the version check found: `nil` when the Server's version is supported.
    public func setServerTooOldVersion(_ version: String?) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO syncState (id, serverTooOldVersion) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET serverTooOldVersion = excluded.serverTooOldVersion
                    """,
                arguments: [version])
        }
    }
}
