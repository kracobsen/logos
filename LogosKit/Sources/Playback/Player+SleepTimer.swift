import Domain
import Foundation

/// The Sleep Timer: Chapter-based only, resolved to an absolute Book-time stop point watched by a boundary observer.
/// It stops hard there and saves the start of the next Chapter. It survives pauses and interruptions (it's not
/// touched by them), lives in memory only, and is cleared when another Book loads or the Book is stopped.
extension Player {
    /// Sets (or re-picks) the Sleep Timer to stop at the end of the `count`th Chapter from the position, counting the
    /// Chapter playing as the first.
    public func setSleepTimer(chapters count: Int) {
        guard let book, state != .idle,
            let timer = SleepTimer(chapters: count, from: position, in: book.chapters, bookDuration: book.duration)
        else { return }
        arm(timer)
    }

    public func cancelSleepTimer() {
        sleepTimerObservation?.cancel()
        sleepTimerObservation = nil
        sleepTimer = nil
    }

    private func arm(_ timer: SleepTimer) {
        cancelSleepTimer()
        sleepTimer = timer
        // A stop at the end of the Book is the end of the Book: that handling stops and saves there.
        guard !timer.endsBook else { return }
        sleepTimerObservation = audio.observeBoundaries([timer.stopAt]) { [weak self] _ in
            self?.sleepTimerReached()
        }
    }

    private func sleepTimerReached() {
        guard let timer = sleepTimer, state == .playing else { return }
        cancelSleepTimer()
        log.notice("Sleep Timer stop at \(timer.stopAt, privacy: .public) s")
        pause(because: .sleepTimer, landingAt: timer.resumeAt)
    }

    /// A seek past the stop point means the boundary can't be reached any more: the Sleep Timer is cleared.
    func sleepTimerSeeked(to target: Double) {
        guard let timer = sleepTimer, target >= timer.stopAt else { return }
        cancelSleepTimer()
    }
}
