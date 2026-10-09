import Foundation

/// The audio-session seam: what the system does to Logos's audio on its own (calls, headphones, the car, media
/// services glitches), reported to the ``Player`` engine, which owns the rules. ``SystemAudioSession`` is the real one
/// (iOS 27 audio-session lifecycle notifications plus route changes and media-services resets), ``FakeAudioSession``
/// the one engine tests script.
public protocol AudioSession: AnyObject {
    /// Things that happen to the session. Set by the engine.
    var onEvent: ((AudioSessionEvent) -> Void)? { get set }
}

/// Something the system did to the audio session.
public enum AudioSessionEvent: Sendable, Hashable {
    /// The system took the session away (a call, Siri, an alarm, another app's audio). Audio has stopped.
    case interrupted
    /// The interruption is over, and whether the system recommends resuming.
    case interruptionEnded(shouldResume: Bool)
    /// The device audio was playing to went away (headphones unplugged, Bluetooth or the car disconnected). The
    /// system pauses the player; left alone, audio would go to the speaker.
    case routeLost
    /// A new output device came along (headphones plugged in, Bluetooth or the car connected). Audio moves to it.
    case routeAdded
    /// The media services were reset: every audio object is gone and has to be rebuilt.
    case mediaServicesReset
}

/// An ``AudioSession`` for tests: ``send(_:)`` reports an event as the system would.
public final class FakeAudioSession: AudioSession {
    public var onEvent: ((AudioSessionEvent) -> Void)?

    public init() {}

    public func send(_ event: AudioSessionEvent) {
        onEvent?(event)
    }
}
