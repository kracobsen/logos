import Foundation

/// Playing stopped, and why: what the listening-sessions outbox follows to end sessions and send straight away.
public struct PlaybackStop: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// The listener paused (or something paused on their behalf).
        case paused
        /// The Sleep Timer reached its stop point.
        case sleepTimer
        /// Playing reached the end of the Book.
        case endOfBook
        /// Another Book was started while this one played.
        case switchedBook
        /// The Book was stopped and unloaded (its Download is going away).
        case stopped
        /// The Book's files couldn't be played any more.
        case failed
        /// A call or other interruption took the audio session (playing may resume when it ends).
        case interrupted
        /// The headphones, Bluetooth or car playing went away.
        case routeLost
        /// The media services were reset; the player was rebuilt paused at the saved position.
        case mediaServicesReset
    }

    public let bookID: String
    /// Where the Book was saved, in Book seconds.
    public let position: Double
    public let reason: Reason

    public init(bookID: String, position: Double, reason: Reason) {
        self.bookID = bookID
        self.position = position
        self.reason = reason
    }
}

extension Player {
    /// Every time playing stops from now on, reported after the position is saved. Only a playing Book stops:
    /// pausing a paused one, or switching away from it, reports nothing. Each call gets its own stream; it ends when
    /// the caller stops iterating.
    public func stops() -> AsyncStream<PlaybackStop> {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackStop.self)
        let id = UUID()
        stopObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stopObservers[id] = nil }
        }
        return stream
    }

    func reportStop(_ stop: PlaybackStop) {
        endListeningSession(after: stop)
        for observer in stopObservers.values { observer.yield(stop) }
    }
}
