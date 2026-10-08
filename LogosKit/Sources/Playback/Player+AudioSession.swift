import Foundation

/// The rules for what the system does to the audio session.
extension Player {
    func handle(_ event: AudioSessionEvent) {
        switch event {
        case .interrupted:
            guard state == .playing else { return }
            pause(because: .interrupted)
            resumesAfterInterruption = true
        case .interruptionEnded(let shouldResume):
            let resumes = resumesAfterInterruption && shouldResume
            resumesAfterInterruption = false
            if resumes { play() }
        case .routeLost:
            // Never resumes by itself, not even when an interruption going on ends.
            resumesAfterInterruption = false
            pause(because: .routeLost)
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
        let wasPlaying = state == .playing
        state = .loading
        var saved = position
        do {
            saved = try database.progress(ofBook: book.id)?.position ?? position
        } catch {
            log.error("Couldn't read the saved position: \(String(describing: error), privacy: .public)")
        }
        saved = min(max(saved, 0), book.duration)
        // Not through `pause(because:)`: the dead player's time can't be trusted, and the saved position stands.
        if wasPlaying { reportStop(PlaybackStop(bookID: book.id, position: saved, reason: .mediaServicesReset)) }
        guard await reload(book, at: saved) else { return }
        state = .paused
    }
}
