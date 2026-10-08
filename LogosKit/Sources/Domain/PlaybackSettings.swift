import Foundation

/// The listener's playback settings: one global speed, and separate Skip back and Skip forward intervals.
public struct PlaybackSettings: Sendable, Hashable {
    /// One of ``PlaybackSpeed/all``.
    public var speed: Double
    public var skipBack: SkipInterval
    public var skipForward: SkipInterval

    public init(speed: Double = 1, skipBack: SkipInterval = .fifteen, skipForward: SkipInterval = .thirty) {
        self.speed = PlaybackSpeed.normalized(speed)
        self.skipBack = skipBack
        self.skipForward = skipForward
    }

    /// 1×, skip back 15 s, skip forward 30 s.
    public static let `default` = PlaybackSettings()
}

/// How far a skip moves.
public enum SkipInterval: Int, Sendable, Hashable, CaseIterable {
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    public var seconds: Double { Double(rawValue) }
}

/// The speeds the listener can pick: 0.5× to 3.0× in 0.05 steps.
public enum PlaybackSpeed {
    public static let minimum = 0.5
    public static let maximum = 3.0
    public static let step = 0.05
    /// The quick picks, in the player and on the lock screen.
    public static let presets: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]
    /// Every speed, slowest first.
    public static let all: [Double] = (10...60).map { Double($0) / 20 }

    /// The nearest speed there is to `speed` (1× if it isn't a number).
    public static func normalized(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        let steps = (min(max(speed, minimum), maximum) * 20).rounded()
        return steps / 20
    }

    /// "1.0×", "1.25×": one decimal unless the speed needs two.
    public static func label(_ speed: Double) -> String {
        let hundredths = Int((normalized(speed) * 100).rounded())
        let format = hundredths % 10 == 0 ? "%.1f×" : "%.2f×"
        return String(format: format, Double(hundredths) / 100)
    }
}
