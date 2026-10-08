import Foundation

/// One stretch of listening to one Book, reported to the Server as a listening session (`POST /api/session/local-all`).
///
/// Logos makes the id (a UUID). A session starts when a Book plays and none is open for it, stays open across pauses
/// shorter than ``ListeningSessions/maxPause``, and ends on a longer pause, a Book switch, Finished or a Sleep Timer
/// stop. Every position write updates its totals, so the outbox only ever holds a session's latest state.
public struct ListeningSession: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let bookID: String
    /// Where listening started, in Book seconds.
    public var startTime: Double
    /// The latest position, in Book seconds.
    public var currentTime: Double
    /// Real (wall-clock) seconds spent playing, whatever the speed.
    public var timeListening: Double
    /// When the listener pressed Play. Kept to the millisecond.
    public var startedAt: Date
    /// The last-changed time of the latest position write: when the user acted, never when it was sent.
    public var updatedAt: Date
    /// Listening is counted up to here: the latest write while playing, or the moment it paused.
    public var listenedUntil: Date
    /// Playing at the latest write, so the time until the next write counts as listening.
    public var isPlaying: Bool
    /// Still open: playing again soon continues it rather than starting another.
    public var isOpen: Bool

    public init(
        id: UUID,
        bookID: String,
        startTime: Double,
        currentTime: Double,
        timeListening: Double,
        startedAt: Date,
        updatedAt: Date,
        listenedUntil: Date,
        isPlaying: Bool,
        isOpen: Bool
    ) {
        self.id = id
        self.bookID = bookID
        self.startTime = startTime
        self.currentTime = currentTime
        self.timeListening = timeListening
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.listenedUntil = listenedUntil
        self.isPlaying = isPlaying
        self.isOpen = isOpen
    }

    /// The id as the Server sees it (lowercase).
    public var serverID: String { id.uuidString.lowercased() }

    /// Whether the session has been paused for ``ListeningSessions/maxPause`` or longer at `now`.
    public func hasPausedTooLong(at now: Date) -> Bool {
        !isPlaying && now.timeIntervalSince(listenedUntil) >= ListeningSessions.maxPause
    }

    /// The session ended: nothing more is added to it.
    public func ended() -> ListeningSession {
        var ended = self
        ended.isOpen = false
        ended.isPlaying = false
        return ended
    }
}

/// The rules that keep listening sessions from position writes.
public enum ListeningSessions {
    /// A pause this long (or longer) ends the session; a shorter one keeps it open.
    public static let maxPause: TimeInterval = 10 * 60

    /// The sessions a position write changes, given every open session.
    ///
    /// The write's last-changed time is "now". Only one Book plays at a time, so a write while playing ends every
    /// other Book's open session; any session paused too long ends too. The written Book's open session takes the
    /// position and the time, and counts the real seconds since its last write if it was playing. A write while
    /// playing with no open session (or one paused too long) starts a session there. A Finished Book's session ends.
    public static func recording(
        _ progress: BookProgress,
        isPlaying: Bool,
        open: [ListeningSession],
        newID: () -> UUID = UUID.init
    ) -> [ListeningSession] {
        let now = progress.lastChanged
        var changed: [ListeningSession] = []
        var current: ListeningSession?
        for session in open where session.isOpen {
            if session.bookID == progress.bookID, current == nil, !session.hasPausedTooLong(at: now) {
                current = session
            } else if session.bookID == progress.bookID || isPlaying || session.hasPausedTooLong(at: now) {
                changed.append(session.ended())
            }
        }
        if var session = current {
            if session.isPlaying {
                session.timeListening += max(now.timeIntervalSince(session.listenedUntil), 0)
            }
            if session.isPlaying || isPlaying { session.listenedUntil = now }
            session.isPlaying = isPlaying
            session.currentTime = progress.position
            session.updatedAt = now
            changed.append(progress.isFinished ? session.ended() : session)
        } else if isPlaying, !progress.isFinished {
            changed.append(
                ListeningSession(
                    id: newID(), bookID: progress.bookID, startTime: progress.position,
                    currentTime: progress.position, timeListening: 0, startedAt: now, updatedAt: now,
                    listenedUntil: now, isPlaying: true, isOpen: true))
        }
        return changed
    }
}

/// A listening session in the outbox, ready to send: its latest state, the revision that state is, and the Book's
/// details the Server likes to have.
public struct OutboxSession: Sendable, Hashable {
    public let session: ListeningSession
    /// Bumped on every change. Confirming a revision delivers that state, not a later one.
    public let revision: Int
    /// The Book's media id (`bookId` in the session).
    public let mediaID: String
    public let title: String
    public let authorName: String
    /// In seconds.
    public let duration: Double

    public init(
        session: ListeningSession, revision: Int, mediaID: String, title: String, authorName: String,
        duration: Double
    ) {
        self.session = session
        self.revision = revision
        self.mediaID = mediaID
        self.title = title
        self.authorName = authorName
        self.duration = duration
    }
}

/// The Server's answer for one sent session.
public struct SessionResult: Sendable, Hashable {
    /// The session's id, as sent (lowercase).
    public let id: String
    /// The Server stored this session. `progressSynced: false` (the Server's progress was newer) still counts.
    public let isDelivered: Bool
    /// When not delivered, the Server's reason (e.g. "Media item not found").
    public let error: String?

    public init(id: String, isDelivered: Bool, error: String? = nil) {
        self.id = id
        self.isDelivered = isDelivered
        self.error = error
    }
}

/// Who is sending sessions, so the Server keeps one device row for this install.
public struct ClientDevice: Sendable, Hashable {
    public let deviceID: String
    public let clientName: String
    public let clientVersion: String
    public let manufacturer: String
    public let model: String
    public let sdkVersion: String

    public init(
        deviceID: String, clientName: String = "Logos", clientVersion: String, manufacturer: String = "Apple",
        model: String, sdkVersion: String
    ) {
        self.deviceID = deviceID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
        self.sdkVersion = sdkVersion
    }
}
