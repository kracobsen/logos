import GRDB

extension AppDatabase {
    /// The Book to restore in the player at launch: the most recently changed downloaded Book (In Progress uses the
    /// same ordering), or `nil`.
    public func lastPlayedBookID() throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT progress.bookID
                    FROM progress JOIN download ON download.bookID = progress.bookID
                    WHERE download.state = 'downloaded'
                    ORDER BY progress.lastChanged DESC, progress.bookID
                    LIMIT 1
                    """
            )
        }
    }
}
