import Foundation

/// When leaving a Book makes it Finished: at the end, or when it's paused or skipped to within its last
/// ``window`` seconds. A Finished Book keeps its position at the end.
public enum FinishRule {
    /// How close to the end counts as the end, in seconds.
    public static let window: TimeInterval = 30

    /// Whether stopping at `position` (Book seconds) finishes a Book `duration` seconds long. A Book of unknown
    /// length (0) never finishes this way.
    public static func finishes(at position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && duration - position <= window
    }
}
