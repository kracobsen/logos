import Foundation

/// The rules for what the system does to the audio session.
extension Player {
    func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interrupted:
            guard state == .playing else { return }
            pause()
            resumesAfterInterruption = true
        case .interruptionEnded(let shouldResume):
            let resumes = resumesAfterInterruption && shouldResume
            resumesAfterInterruption = false
            if resumes { play() }
        case .routeLost:
            resumesAfterInterruption = false
            pause()
        case .routeAdded:
            guard state == .playing else { return }
            position = audio.currentTime
            save()
        case .mediaServicesReset:
            Task { await rebuildAfterReset() }
        }
    }

    /// Every audio object died with the media services: rebuild the player and load the Book again paused at its
    /// saved position. The old player can't be asked where it was, and the last save is at most a second old.
    private func rebuildAfterReset() async {
        log.notice("Media services were reset; rebuilding the player")
        resumesAfterInterruption = false
        saving?.cancel()
        saving = nil
        audio.rebuild()
        guard let book, state != .idle else { return }
        state = .loading
        let saved: Double
        do {
            saved = try database.progress(ofBook: book.id)?.position ?? position
        } catch {
            log.error("Couldn't read the saved position: \(String(describing: error), privacy: .public)")
            saved = position
        }
        guard await reload(book, at: min(max(saved, 0), book.duration)) else { return }
        state = .paused
    }
}
