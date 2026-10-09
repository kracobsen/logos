import Domain
import Store

extension PlaybackStop.Reason {
    /// Whether this stop ends the Book's listening session. A pause (the listener's, an interruption, a lost route, a media-services reset) keeps it open (playing again within
    /// ``ListeningSessions/maxPause`` continues it); a Sleep Timer stop, a Book switch and the end of the Book end it.
    public var endsListeningSession: Bool {
        switch self {
        // System pauses are pauses: the session stays open, and resuming within 10 minutes continues it.
        case .paused, .interrupted, .routeLost, .mediaServicesReset: false
        case .sleepTimer, .endOfBook, .switchedBook, .stopped, .failed: true
        }
    }
}

extension Player {
    /// Ends the Book's listening session if the stop calls for it. Runs before the stop is reported, so whoever
    /// sends the outbox on a stop sends the ended session.
    func endListeningSession(after stop: PlaybackStop) {
        guard stop.reason.endsListeningSession else { return }
        do {
            try database.endListeningSession(ofBook: stop.bookID)
        } catch {
            log.error("Couldn't end the listening session: \(String(describing: error), privacy: .public)")
        }
    }
}
