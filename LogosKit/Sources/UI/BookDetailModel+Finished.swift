import Domain
import Playback

/// Book detail's Finished icon: Mark as Finished while the Book isn't, Clear Finished once it is.
public enum FinishedToggle: Sendable, Hashable {
    case mark
    case clear

    /// Tapping it sets Finished (Mark as Finished) or clears it.
    public var setsFinished: Bool { self == .mark }

    public var title: String {
        switch self {
        case .mark: "Mark as Finished"
        case .clear: "Clear Finished"
        }
    }

    public var systemImage: String {
        switch self {
        case .mark: "checkmark.circle"
        case .clear: "checkmark.circle.fill"
        }
    }

    public var hint: String {
        switch self {
        case .mark: "Puts the Book at its end"
        case .clear: "Moves the Book back to its start"
        }
    }
}

extension BookDetailModel {
    /// The Book is Finished (Book detail offers Clear Finished rather than Mark as Finished).
    public var isFinished: Bool { progress.status == .finished }

    /// What Book detail's Finished icon does now.
    public var finishedToggle: FinishedToggle { isFinished ? .clear : .mark }

    /// Sets or clears Finished by hand: Finished puts the Book at its end (stopping it if it's playing), clearing it
    /// moves it to 0. Always through the player, the one path that stamps it with the Clock (whether the Book is
    /// loaded or not).
    public func setFinished(_ finished: Bool, player: Player) {
        player.setFinished(finished, bookID: bookID)
    }
}
