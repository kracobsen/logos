import Domain
import Store

/// The global speed and the skip intervals. The engine reads them from the Store at init and saves each change there.
extension Player {
    /// The speed as the player takes it.
    public var rate: Float { Float(speed) }

    /// Sets the global speed (the nearest of ``PlaybackSpeed/all``): playing changes speed at once, and it's kept for
    /// the next launch. Positions stay in Book time.
    public func setSpeed(_ speed: Double) {
        let speed = PlaybackSpeed.normalized(speed)
        self.speed = speed
        audio.rate = Float(speed)
        do {
            try database.setPlaybackSpeed(speed)
        } catch {
            log.error("Couldn't save the speed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Skips back by the Skip back setting. Saves.
    public func skipBack() {
        skip(by: -skipBackInterval.seconds)
    }

    /// Skips forward by the Skip forward setting. Saves.
    public func skipForward() {
        skip(by: skipForwardInterval.seconds)
    }

    public func setSkipBackInterval(_ interval: SkipInterval) {
        skipBackInterval = interval
        do {
            try database.setSkipBack(interval)
        } catch {
            log.error("Couldn't save Skip back: \(String(describing: error), privacy: .public)")
        }
    }

    public func setSkipForwardInterval(_ interval: SkipInterval) {
        skipForwardInterval = interval
        do {
            try database.setSkipForward(interval)
        } catch {
            log.error("Couldn't save Skip forward: \(String(describing: error), privacy: .public)")
        }
    }

    static func readSettings(_ database: AppDatabase) -> PlaybackSettings {
        do {
            return try database.playbackSettings()
        } catch {
            log.error("Couldn't read the playback settings: \(String(describing: error), privacy: .public)")
            return .default
        }
    }
}
