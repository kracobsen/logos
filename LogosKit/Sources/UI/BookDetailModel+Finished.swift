import Domain
import Foundation
import Playback
import Store

extension BookDetailModel {
    /// The Book is Finished (Book detail offers Clear Finished rather than Mark as Finished).
    public var isFinished: Bool { progress.status == .finished }

    /// Sets or clears Finished by hand: Finished puts the Book at its end (stopping it if it's playing), clearing it
    /// moves it to 0. Goes through the player when there is one, so a loaded Book follows.
    public func setFinished(_ finished: Bool, player: Player?) {
        if let player {
            player.setFinished(finished, bookID: bookID)
            return
        }
        do {
            try database.setFinished(finished, ofBook: bookID, at: Date())
        } catch {
            log.error("Couldn't set Finished: \(String(describing: error), privacy: .public)")
        }
    }
}
