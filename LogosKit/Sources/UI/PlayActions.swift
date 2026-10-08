import Domain
import Playback

/// What a downloaded Book's primary button does.
public enum PlayAction: Sendable, Hashable {
    case play
    case resume
    case pause

    var title: String {
        switch self {
        case .play: "Play"
        case .resume: "Resume"
        case .pause: "Pause"
        }
    }

    var systemImage: String {
        switch self {
        case .play, .resume: "play.fill"
        case .pause: "pause.fill"
        }
    }
}

extension Player {
    /// The button for a downloaded Book: Pause while it plays, Resume when it's loaded part-way or `resumes` (the
    /// listener has started it), else Play.
    public func action(forBook bookID: String, resumes: Bool) -> PlayAction {
        if book?.id == bookID {
            if state == .playing || state == .loading { return .pause }
            if position > 0, !isFinished { return .resume }
            return .play
        }
        return resumes ? .resume : .play
    }

    /// The Book's play button was tapped: pauses it if it's playing, else plays it (switching Books if needed).
    public func tapped(bookID: String) {
        if book?.id == bookID, state == .playing {
            pause()
        } else {
            Task { await play(bookID: bookID) }
        }
    }
}

extension BookProgressStatus {
    /// Started and not Finished: a downloaded Book offers Resume.
    var isStarted: Bool {
        if case .inProgress = self { return true }
        return false
    }
}
