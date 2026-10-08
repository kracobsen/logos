import Foundation
import GRDB

/// The one GRDB database that holds the Library and user data (ADR 0001: the single source of truth).
///
/// Wraps the `Sendable` `DatabasePool`. Migrations are added to ``migrator`` by hand, in order.
public struct AppDatabase: Sendable {
    let pool: DatabasePool

    /// Opens (creating if needed) the database at `url` and runs pending migrations.
    /// Never deletes the file: if it can't be opened or migrated, the error is thrown and the file is kept.
    public static func open(at url: URL) throws -> AppDatabase {
        let pool = try DatabasePool(path: url.path())
        try migrator.migrate(pool)
        return AppDatabase(pool: pool)
    }

    static var migrator: DatabaseMigrator {
        DatabaseMigrator()
    }
}
