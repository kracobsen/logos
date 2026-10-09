import Domain
import Foundation
import Store

/// Picked up from another device: when a progress fetch wins for the paused, loaded Book, the player moves to the
/// Server's position and says so, with a way back. A playing Book is never moved: its own position is saved straight
/// back, so it stays the newest.
extension Player {
    /// The paused Book moved to where another device left it.
    public nonisolated struct PickedUp: Sendable, Hashable {
        /// The Server's position, in Book seconds.
        public let position: Double
        /// Whether the Server had the Book Finished.
        public let isFinished: Bool

        public init(position: Double, isFinished: Bool) {
            self.position = position
            self.isFinished = isFinished
        }
    }

    /// Follows applied progress fetches until cancelled, picking up the loaded Book when it's paused.
    public func observePickUps() async {
        for await adopted in database.fetchedProgressUpdates() {
            guard let bookID = book?.id, let progress = adopted.first(where: { $0.bookID == bookID }) else {
                continue
            }
            pickUp(progress)
        }
    }

    /// Goes back to where the Book was before it was picked up. A local seek: saved now, so it's newer than the
    /// Server and wins next time.
    public func undoPickUp() {
        guard pickedUp != nil, let before = beforePickUp else { return }
        clearPickUp()
        move(to: before.position, isFinished: before.isFinished)
        save()
    }

    /// Hides the notice, staying at the picked-up position.
    public func dismissPickUp() {
        clearPickUp()
    }

    func clearPickUp() {
        pickedUp = nil
        beforePickUp = nil
        pendingPickUp = nil
    }

    /// Picks up a fetch held while the Book was loading.
    func pickUpPending() {
        guard let progress = pendingPickUp else { return }
        pendingPickUp = nil
        pickUp(progress)
    }

    private func pickUp(_ progress: BookProgress) {
        if isReloading {
            // The reload would land on its own position over it: picked up once it's done.
            pendingPickUp = progress
            return
        }
        switch state {
        case .idle:
            return
        case .loading:
            pendingPickUp = progress
        case .playing:
            // Never yanked mid-listen: overwrite the fetch with where the listener is, as now.
            catchUpPosition()
            save()
        case .paused:
            let isChange =
                abs(progress.position - position) > ProgressMerge.positionTolerance
                || progress.isFinished != isFinished
            let before = beforePickUp ?? (position, isFinished)
            move(to: progress.position, isFinished: progress.isFinished)
            guard isChange else { return }
            beforePickUp = before
            pickedUp = PickedUp(position: position, isFinished: isFinished)
        }
    }
}
