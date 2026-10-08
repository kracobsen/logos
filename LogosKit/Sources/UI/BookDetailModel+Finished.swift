import Domain
import Playback

extension BookDetailModel {
    /// The Book is Finished (Book detail offers Clear Finished rather than Mark as Finished).
    public var isFinished: Bool { progress.status == .finished }

    /// Sets or clears Finished by hand: Finished puts the Book at its end (stopping it if it's playing), clearing it
    /// moves it to 0. Always through the player, the one path that stamps it with the Clock (whether the Book is
    /// loaded or not).
    public func setFinished(_ finished: Bool, player: Player) {
        player.setFinished(finished, bookID: bookID)
    }
}
