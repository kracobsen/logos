import Foundation

/// A local change to a Book's Finished state, waiting in the outbox to reach the Server
/// (`PATCH /api/me/progress/:libraryItemId`).
///
/// Every local change to Finished queues one (Finished at the end of a Book or by hand, cleared by hand or by Play).
/// A Book has at most one: a later change replaces it, since the Server only needs the latest state.
public struct FinishedChange: Sendable, Hashable {
    public let bookID: String
    public let isFinished: Bool
    /// The position after the change, in Book seconds: the end of the Book when Finished, 0 when cleared.
    public let position: Double
    /// When the listener acted. Kept to the millisecond.
    public let lastUpdate: Date

    public init(bookID: String, isFinished: Bool, position: Double, lastUpdate: Date) {
        self.bookID = bookID
        self.isFinished = isFinished
        self.position = position
        self.lastUpdate = lastUpdate
    }
}

/// A Finished change ready to send, with the Book's duration (the Server gets it with a Finished Book, so its record
/// counts as at the end).
public struct PendingFinishedChange: Sendable, Hashable {
    public let change: FinishedChange
    /// In seconds.
    public let duration: Double

    public init(change: FinishedChange, duration: Double) {
        self.change = change
        self.duration = duration
    }
}

/// The rules for sending a ``FinishedChange``.
public enum FinishedChanges {
    /// Whether the Server's progress was changed after the listener acted (last-writer-wins, ties keep the local
    /// change): the change is then dropped and the Server's state applied. Ask before sending the Book's sessions,
    /// since the Server stamps progress that a session *creates* with its own time.
    public static func isOverruled(_ change: FinishedChange, by server: FetchedProgress?) -> Bool {
        guard let server else { return false }
        return server.lastUpdate > change.lastUpdate.millisecondsSince1970
    }

    /// Whether the Server already has the change's Finished state (no progress counts as not Finished), so there's
    /// nothing to send. A session that reaches the end finishes the Book on the Server, and one played from a
    /// Finished Book clears it there.
    public static func isOnServer(_ change: FinishedChange, server: FetchedProgress?) -> Bool {
        (server?.isFinished ?? false) == change.isFinished
    }
}
