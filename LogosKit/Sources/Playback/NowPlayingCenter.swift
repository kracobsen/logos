import Foundation

/// What the lock screen, Control Center and accessories show for the loaded Book, and which controls they offer.
public struct NowPlayingState: Sendable, Hashable {
    public var item: NowPlayingItem
    public var playback: NowPlayingPlayback
    public var controls: NowPlayingControls

    public init(item: NowPlayingItem, playback: NowPlayingPlayback, controls: NowPlayingControls) {
        self.item = item
        self.playback = playback
        self.controls = controls
    }
}

/// The current Chapter of the loaded Book: progress and scrubbing are Chapter-scoped.
public struct NowPlayingItem: Sendable, Hashable {
    public var bookID: String
    /// The Chapter name.
    public var title: String
    /// The Book title and author ("Title · Author"), or the title alone.
    public var subtitle: String
    public var narratorName: String?
    /// 1-based.
    public var chapterNumber: Int
    public var chapterCount: Int
    /// Where the Chapter starts, in Book seconds (a seek command's time is relative to it).
    public var chapterStart: Double
    /// The Chapter's length, in Book seconds.
    public var duration: Double
    /// The cover file, if the Book has one on disk.
    public var coverURL: URL?

    public init(
        bookID: String,
        title: String,
        subtitle: String,
        narratorName: String?,
        chapterNumber: Int,
        chapterCount: Int,
        chapterStart: Double,
        duration: Double,
        coverURL: URL?
    ) {
        self.bookID = bookID
        self.title = title
        self.subtitle = subtitle
        self.narratorName = narratorName
        self.chapterNumber = chapterNumber
        self.chapterCount = chapterCount
        self.chapterStart = chapterStart
        self.duration = duration
        self.coverURL = coverURL
    }
}

/// Whether the Book plays, and where in the Chapter it was at `date`; the system extrapolates from there.
public struct NowPlayingPlayback: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// The Book's files are loading.
        case loading
        case paused
        /// Playing at `rate` (the speed).
        case playing(rate: Double)
    }

    public var status: Status
    /// The speed playing runs (or will run) at.
    public var speed: Double
    /// Seconds into the Chapter, in Book time.
    public var elapsed: Double
    /// When `elapsed` was read.
    public var date: Date

    public init(status: Status, speed: Double, elapsed: Double, date: Date) {
        self.status = status
        self.speed = speed
        self.elapsed = elapsed
        self.date = date
    }

    /// Where the system thinks the Chapter is at `now`.
    func extrapolated(to now: Date) -> Double {
        guard case .playing(let rate) = status else { return elapsed }
        return elapsed + now.timeIntervalSince(date) * rate
    }
}

/// The controls on offer: both skips with the configured intervals (next/previous track map to them) and a speed
/// menu.
public struct NowPlayingControls: Sendable, Hashable {
    /// In seconds.
    public var skipBack: Double
    /// In seconds.
    public var skipForward: Double
    /// The speed menu.
    public var speeds: [Double]

    public init(skipBack: Double, skipForward: Double, speeds: [Double]) {
        self.skipBack = skipBack
        self.skipForward = skipForward
        self.speeds = speeds
    }
}

/// A control used on the lock screen, in Control Center, or on AirPods, a headset or the car.
public enum NowPlayingCommand: Sendable, Hashable {
    case play
    case pause
    case togglePlayPause
    case skipBack
    case skipForward
    case previousTrack
    case nextTrack
    /// Scrubbing: seconds into the Chapter shown.
    case seek(to: Double)
    case changeSpeed(Double)
}

/// The seam to the system's Now Playing: shows a state (nil = nothing loaded) and reports commands.
///
/// Real: ``SystemNowPlayingCenter`` (iOS 27's NowPlaying framework). Fake: ``FakeNowPlayingCenter``.
public protocol NowPlayingCenter: AnyObject {
    /// Called on the main actor for every command.
    var onCommand: ((NowPlayingCommand) -> Void)? { get set }

    func show(_ state: NowPlayingState?)

    /// The media services were reset: whatever was published is gone. The next ``show(_:)`` publishes afresh.
    func reset()
}

/// Records what it was asked to show and sends commands as if the system had.
public final class FakeNowPlayingCenter: NowPlayingCenter {
    public var onCommand: ((NowPlayingCommand) -> Void)?
    /// Every state shown, in order.
    public private(set) var shown: [NowPlayingState?] = []

    public init() {}

    /// The state shown last.
    public var state: NowPlayingState? { shown.last ?? nil }

    public func show(_ state: NowPlayingState?) {
        shown.append(state)
    }

    /// How many times ``reset()`` was called.
    public private(set) var resetCount = 0

    public func reset() {
        resetCount += 1
    }

    /// Sends a command, as the lock screen, Control Center or an accessory would.
    public func send(_ command: NowPlayingCommand) {
        onCommand?(command)
    }
}
