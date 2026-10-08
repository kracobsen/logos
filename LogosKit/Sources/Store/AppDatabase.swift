import Foundation
import GRDB

/// The one GRDB database that holds the Library and user data (ADR 0001: the single source of truth).
///
/// Wraps the `Sendable` `DatabasePool` (WAL mode), with `synchronous=FULL` so a committed transaction survives power
/// loss. The file is left in backups: put it in Application Support, never mark it excluded. Migrations are added to
/// ``migrator`` by hand, in order, and are never edited once shipped.
public struct AppDatabase: Sendable {
    let pool: DatabasePool

    /// Why the database couldn't be opened, beyond SQLite's own errors.
    public enum OpenError: Error, Sendable, Hashable {
        /// The file was migrated by a newer Logos; this one doesn't know its schema.
        case fromNewerVersion
    }

    /// Opens (creating if needed) the database at `url` and runs pending migrations.
    ///
    /// Never deletes or resets the file: if it can't be opened or migrated, the error is thrown and the file is kept,
    /// so the app can show an error screen instead.
    public static func open(at url: URL) throws -> AppDatabase {
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        // GRDB sets NORMAL on the writer connection when it opens; FULL syncs the WAL on every commit.
        try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
        if try pool.read(migrator.hasBeenSuperseded) {
            throw OpenError.fromNewerVersion
        }
        try migrator.migrate(pool)
        return AppDatabase(pool: pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-serverIdentity") { db in
            // One row at most (id is always 1): the Server, user and Library Logos is signed in to.
            try db.create(table: "serverIdentity") { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("serverURL", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("username", .text).notNull()
                table.column("libraryID", .text).notNull()
                table.column("libraryName", .text).notNull()
            }
        }
        migrator.registerMigration("v2-library") { db in
            // One row per Book. Stage 1 writes the list columns; the later stages own their version columns.
            try db.create(table: "book") { table in
                table.primaryKey("id", .text)
                table.column("mediaID", .text).notNull()
                table.column("title", .text).notNull()
                table.column("subtitle", .text)
                table.column("authorName", .text).notNull()
                table.column("authorNameLF", .text).notNull()
                table.column("narratorName", .text).notNull()
                table.column("seriesName", .text).notNull()
                table.column("description", .text)
                table.column("publishedYear", .text)
                table.column("genres", .jsonText).notNull()
                table.column("addedAt", .integer).notNull()  // ms since 1970
                table.column("updatedAt", .integer).notNull()  // the Server's ms; the version stages 2 and 3 chase
                table.column("duration", .double).notNull()
                table.column("size", .integer).notNull()
                table.column("hasCover", .boolean).notNull()
                // Stage 2 (full Book data) and stage 3 (cover): the `updatedAt` each was last fetched at, or NULL.
                // A stage is behind for a Book when its version differs from `updatedAt`.
                table.column("fullDataVersion", .integer)
                table.column("coverVersion", .integer)
            }
            // One row at most (id is always 1): sync bookkeeping that isn't per Book.
            try db.create(table: "syncState") { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("lastLibrarySync", .double)  // seconds since 1970, of the last applied list
            }
        }
        registerBookDataMigration(in: &migrator)
        return migrator
    }

    /// The value `fetch` reads now, then again after every change that could alter it.
    func observe<Value: Sendable & Equatable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, any Error> {
        let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: pool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
