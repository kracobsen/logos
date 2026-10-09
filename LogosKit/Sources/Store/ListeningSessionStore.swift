import Domain
import Foundation
import GRDB

/// A `listeningSession` row: one listening session in the outbox, with the revision of its state.
///
/// Not a foreign key to `book`: like progress, unsent listening outlives its Book leaving the Library. Rows go only
/// when the Server has confirmed their latest state and they're closed, or with their Not on Server Book when its
/// Download is removed.
struct ListeningSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "listeningSession"

    var id: String
    var bookID: String
    var startTime: Double
    var currentTime: Double
    var timeListening: Double
    var startedAt: Int64  // ms since 1970
    var updatedAt: Int64  // ms since 1970
    var listenedUntil: Int64  // ms since 1970
    var isPlaying: Bool
    var isOpen: Bool
    /// Bumped on every change.
    var revision: Int
    /// The latest revision the Server confirmed (0: none). The session is unsent while this is below `revision`.
    var sentRevision: Int

    init(_ session: ListeningSession, revision: Int, sentRevision: Int) {
        id = session.serverID
        bookID = session.bookID
        startTime = session.startTime
        currentTime = session.currentTime
        timeListening = session.timeListening
        startedAt = session.startedAt.millisecondsSince1970
        updatedAt = session.updatedAt.millisecondsSince1970
        listenedUntil = session.listenedUntil.millisecondsSince1970
        isPlaying = session.isPlaying
        isOpen = session.isOpen
        self.revision = revision
        self.sentRevision = sentRevision
    }

    var session: ListeningSession {
        ListeningSession(
            id: UUID(uuidString: id) ?? UUID(), bookID: bookID, startTime: startTime, currentTime: currentTime,
            timeListening: timeListening, startedAt: Date(millisecondsSince1970: startedAt),
            updatedAt: Date(millisecondsSince1970: updatedAt),
            listenedUntil: Date(millisecondsSince1970: listenedUntil), isPlaying: isPlaying, isOpen: isOpen)
    }

    /// Whether the state differs from `session` in anything the Server sees.
    func reportsDifferently(from session: ListeningSession) -> Bool {
        let other = ListeningSessionRecord(session, revision: revision, sentRevision: sentRevision)
        return (startTime, currentTime, timeListening, startedAt, updatedAt)
            != (other.startTime, other.currentTime, other.timeListening, other.startedAt, other.updatedAt)
    }
}

extension AppDatabase {
    /// Migration `v6-listening-sessions`: the listening-sessions outbox, and this install's device id.
    static func registerListeningSessionsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-listening-sessions") { db in
            try db.create(table: "listeningSession") { table in
                table.primaryKey("id", .text)
                table.column("bookID", .text).notNull().indexed()
                table.column("startTime", .double).notNull()
                table.column("currentTime", .double).notNull()
                table.column("timeListening", .double).notNull()
                table.column("startedAt", .integer).notNull()
                table.column("updatedAt", .integer).notNull()
                table.column("listenedUntil", .integer).notNull()
                table.column("isPlaying", .boolean).notNull()
                table.column("isOpen", .boolean).notNull()
                table.column("revision", .integer).notNull()
                table.column("sentRevision", .integer).notNull().defaults(to: 0)
            }
            // One row at most (id is always 1): the id the Server knows this install's device by.
            try db.create(table: "clientDevice") { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("deviceID", .text).notNull()
            }
        }
    }

    /// Saves one Book's progress from a position write, and records it in the listening sessions
    /// (``ListeningSessions/recording(_:isPlaying:open:newID:)``), in one transaction.
    ///
    /// - Parameter isPlaying: whether the Book is playing after this write.
    public func saveProgress(_ progress: BookProgress, listening isPlaying: Bool) throws {
        try pool.write { db in
            try Self.writeLocalProgress(progress, db)
            let open = try ListeningSessionRecord.filter(Column("isOpen") == true).fetchAll(db)
            let changed = ListeningSessions.recording(progress, isPlaying: isPlaying, open: open.map(\.session))
            try Self.writeSessions(changed, db)
        }
    }

    /// Ends the Book's open listening session, if any (a Sleep Timer stop, a Book switch, the end of the Book).
    public func endListeningSession(ofBook bookID: String) throws {
        try pool.write { db in try Self.endListeningSessions(db, bookID: bookID) }
    }

    static func endListeningSessions(_ db: Database, bookID: String) throws {
        let open =
            try ListeningSessionRecord
            .filter(Column("isOpen") == true && Column("bookID") == bookID).fetchAll(db)
        try writeSessions(open.map { $0.session.ended() }, db)
    }

    /// Ends every open session with its last saved state. At launch, before anything plays: a session still open
    /// then was left open by a kill.
    public func closeListeningSessionsLeftOpen() throws {
        try pool.write { db in
            let open = try ListeningSessionRecord.filter(Column("isOpen") == true).fetchAll(db)
            try Self.writeSessions(open.map { $0.session.ended() }, db)
        }
    }

    /// Ends every session that has been paused for ``ListeningSessions/maxPause`` or longer at `now`.
    public func closeListeningSessionsPausedTooLong(at now: Date) throws {
        try pool.write { db in
            let open = try ListeningSessionRecord.filter(Column("isOpen") == true).fetchAll(db)
            try Self.writeSessions(open.map(\.session).filter { $0.hasPausedTooLong(at: now) }.map { $0.ended() }, db)
        }
    }

    /// Every session in the outbox, sent or not, oldest first.
    public func listeningSessions() throws -> [ListeningSession] {
        try pool.read { db in
            try ListeningSessionRecord.order(Column("startedAt"), Column("id")).fetchAll(db).map(\.session)
        }
    }

    /// Whether a session is playing now (the 60 s sends run only then).
    public func isListening() throws -> Bool {
        try pool.read { db in
            try ListeningSessionRecord.filter(Column("isPlaying") == true && Column("isOpen") == true).fetchCount(db)
                > 0
        }
    }

    /// The sessions to send: unsent ones whose Book is in the Library and on the Server, latest state first. Sessions
    /// of a Not on Server Book (or one the Library no longer has) are held: kept, not sent.
    ///
    /// Latest first because the Server stamps a Book's progress that a session *creates* with its own time, so any
    /// older session after it in the same send no longer moves the Server's position. Sending the latest first
    /// makes that first progress the listener's latest position.
    public func unsentListeningSessions() throws -> [OutboxSession] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT listeningSession.*, book.mediaID, book.title, book.authorName, book.duration AS bookDuration
                    FROM listeningSession JOIN book ON book.id = listeningSession.bookID
                    WHERE listeningSession.sentRevision < listeningSession.revision AND NOT book.notOnServer
                    ORDER BY listeningSession.updatedAt DESC, listeningSession.id
                    """
            ).map { row in
                let record = try ListeningSessionRecord(row: row)
                return OutboxSession(
                    session: record.session, revision: record.revision, mediaID: row["mediaID"], title: row["title"],
                    authorName: row["authorName"], duration: row["bookDuration"])
            }
        }
    }

    /// The Server confirmed these sessions at these revisions. A closed session whose latest state is confirmed
    /// leaves the outbox; one that changed since (a later revision) stays unsent.
    public func confirmListeningSessions(_ confirmed: [(id: UUID, revision: Int)]) throws {
        try pool.write { db in
            for (id, revision) in confirmed {
                try db.execute(
                    sql: "UPDATE listeningSession SET sentRevision = MAX(sentRevision, ?) WHERE id = ?",
                    arguments: [revision, id.uuidString.lowercased()])
            }
            try Self.deleteDeliveredSessions(db)
        }
    }

    /// This install's device id for the Server, made the first time it's asked for.
    public func clientDeviceID() throws -> String {
        try pool.write { db in
            if let id = try String.fetchOne(db, sql: "SELECT deviceID FROM clientDevice WHERE id = 1") { return id }
            let id = UUID().uuidString.lowercased()
            try db.execute(sql: "INSERT INTO clientDevice (id, deviceID) VALUES (1, ?)", arguments: [id])
            return id
        }
    }

    /// The Books with outbox entries the Server hasn't confirmed (sessions or a Finished change): a fetch never
    /// overwrites their progress.
    static func bookIDsWithUnsentEntries(_ db: Database) throws -> Set<String> {
        try Set(
            String.fetchAll(db, sql: "SELECT DISTINCT bookID FROM listeningSession WHERE sentRevision < revision")
        )
        .union(bookIDsWithPendingFinishedChanges(db))
    }

    /// The Books with sessions the Server hasn't confirmed. A Book's Finished change waits for them.
    public func bookIDsWithUnsentSessions() throws -> Set<String> {
        try pool.read { db in
            try Set(
                String.fetchAll(db, sql: "SELECT DISTINCT bookID FROM listeningSession WHERE sentRevision < revision"))
        }
    }

    /// Deletes a Book's sessions (with the Book itself, when its Download is removed while Not on Server).
    static func deleteListeningSessions(_ db: Database, bookID: String) throws {
        try db.execute(sql: "DELETE FROM listeningSession WHERE bookID = ?", arguments: [bookID])
    }

    /// Writes changed sessions: a new revision when the state the Server sees changed.
    private static func writeSessions(_ sessions: [ListeningSession], _ db: Database) throws {
        for session in sessions {
            let stored = try ListeningSessionRecord.fetchOne(db, key: session.serverID)
            var record = ListeningSessionRecord(
                session, revision: stored?.revision ?? 1, sentRevision: stored?.sentRevision ?? 0)
            if let stored, stored.reportsDifferently(from: session) { record.revision += 1 }
            try record.upsert(db)
        }
        try deleteDeliveredSessions(db)
    }

    private static func deleteDeliveredSessions(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM listeningSession WHERE NOT isOpen AND sentRevision >= revision")
    }
}
