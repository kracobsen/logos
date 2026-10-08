import Foundation

/// The AVPlayer seam: the thin layer the ``Player`` engine drives. ``SystemAudioPlayer`` is the real one (one
/// `AVPlayer` playing an `AVMutableComposition`), ``FakeAudioPlayer`` the one engine tests script.
///
/// Every time is in Book seconds: the timeline is the Book's files back to back, so player time is Book time.
public protocol AudioPlayer: AnyObject {
    /// Replaces whatever was loaded with these files played back to back as one timeline, at 0 and paused. Returns
    /// once it's ready to play. Throws if a file can't be opened or read.
    func load(_ files: [URL]) async throws

    /// Drops the timeline, paused.
    func unload()

    /// Plays at ``rate`` from the current time.
    func play()

    func pause()

    /// The speed playing runs at (1 = normal). Kept while paused and across loads.
    var rate: Float { get set }

    /// Where the timeline is now.
    var currentTime: Double { get }

    /// Moves to `time` exactly; returns once the move is done (audio follows from there).
    func seek(to time: Double) async

    /// Calls `handler` with the current time about every `interval` seconds while time moves, and when it jumps.
    /// Lasts across loads until cancelled.
    func observeTime(every interval: Double, _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation

    /// Calls `handler` with the boundary crossed whenever playing reaches one of `times`. Lasts across loads until
    /// cancelled.
    func observeBoundaries(_ times: [Double], _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation

    /// Things that happen to the player on its own. Set by the engine.
    var onEvent: ((AudioPlayerEvent) -> Void)? { get set }
}

/// Something the player reports by itself.
public enum AudioPlayerEvent: Sendable, Hashable {
    /// Audio is actually coming out after `play()` (or after a seek while playing).
    case startedPlaying
    /// Playing reached the end of the timeline; the player is paused there.
    case playedToEnd
    /// The decoder failed at this time (AVFoundation's -11821 "Cannot Decode"); the player has stopped.
    case decodeFailed(at: Double)
}

/// A time or boundary observer. Call ``cancel()`` to remove it.
public final class AudioPlayerObservation {
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}
