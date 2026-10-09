import Foundation

/// One Book's progress as the Server reports it (`GET /api/me/progress`).
public struct FetchedProgress: Sendable, Hashable {
    /// The library item id.
    public let bookID: String
    /// `currentTime`, in Book seconds.
    public let position: TimeInterval
    public let isFinished: Bool
    /// The Server's `lastUpdate` in ms since 1970: when the user last acted on this Book, as far as the Server knows.
    public let lastUpdate: Int64

    public init(bookID: String, position: TimeInterval, isFinished: Bool, lastUpdate: Int64) {
        self.bookID = bookID
        self.position = position
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
    }
}

/// Where the listener is in one Book: the position, when they last acted on it, and whether it's Finished.
public struct BookProgress: Sendable, Hashable {
    public let bookID: String
    /// In Book seconds.
    public let position: TimeInterval
    /// The wall-clock time the user last acted (played, sought, marked Finished), never when it was sent or fetched.
    /// Last-writer-wins compares it with the Server's `lastUpdate`. Kept to the millisecond.
    public let lastChanged: Date
    public let isFinished: Bool

    public init(bookID: String, position: TimeInterval, lastChanged: Date, isFinished: Bool) {
        self.bookID = bookID
        self.position = position
        self.lastChanged = lastChanged
        self.isFinished = isFinished
    }

    /// In Progress: started and not Finished.
    public var isInProgress: Bool { !isFinished && position > 0 }
}

/// The fetch side of progress sync: whether progress fetched from the Server replaces the local progress.
public enum ProgressMerge {
    /// Positions this close count as the same: a fetch that differs by no more than this (and agrees on Finished)
    /// changes nothing.
    public static let positionTolerance: TimeInterval = 2

    /// The progress to store after fetching `fetched`, or `nil` to keep `local` as it is.
    ///
    /// Last-writer-wins on when the user acted: the fetch wins only if the Server's `lastUpdate` is strictly newer
    /// than the local last-changed time, and then it brings both its position and Finished. A Book with no local
    /// progress counts as not started. A winning fetch within ``positionTolerance`` that agrees on Finished isn't a
    /// change.
    public static func adopting(_ fetched: FetchedProgress, over local: BookProgress?) -> BookProgress? {
        if let local, fetched.lastUpdate <= local.lastChanged.millisecondsSince1970 { return nil }
        let isChange =
            abs(fetched.position - (local?.position ?? 0)) > positionTolerance
            || fetched.isFinished != (local?.isFinished ?? false)
        guard isChange else { return nil }
        return BookProgress(
            bookID: fetched.bookID,
            position: fetched.position,
            lastChanged: Date(millisecondsSince1970: fetched.lastUpdate),
            isFinished: fetched.isFinished
        )
    }
}

extension Date {
    /// Milliseconds since 1970, rounded: the Server's time unit, and how the Store keeps progress times.
    public var millisecondsSince1970: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    public init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

/// One In Progress row: a started, unfinished Book with where the listener is in it.
public struct InProgressRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let authorName: String
    /// In seconds; 0 if the Server didn't say.
    public let duration: TimeInterval
    public let position: TimeInterval
    public let lastChanged: Date
    /// The Server no longer lists the Book (see ``BookDetail/isNotOnServer``).
    public let isNotOnServer: Bool

    public init(
        id: String,
        title: String,
        authorName: String,
        duration: TimeInterval,
        position: TimeInterval,
        lastChanged: Date,
        isNotOnServer: Bool = false
    ) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.duration = duration
        self.position = position
        self.lastChanged = lastChanged
        self.isNotOnServer = isNotOnServer
    }
}
