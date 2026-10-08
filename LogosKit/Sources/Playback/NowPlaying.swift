import Domain
import Foundation
import Observation
import Store

/// Keeps the system's Now Playing (lock screen, Control Center, AirPods, the car, headsets) in step with the player,
/// and plays its commands on the player.
///
/// It shows the current Chapter of the loaded Book (Chapter-scoped progress and scrubbing), the cover, both skips
/// with the configured intervals and a speed menu with the presets; nothing about the Sleep Timer.
public final class NowPlaying {
    private let player: Player
    private let center: any NowPlayingCenter
    private let covers: CoverFiles?
    private let clock: any Clock
    /// The state shown last.
    private var shown: NowPlayingState?
    private var hasShown = false
    /// ``Player/mediaServicesResets`` when last shown.
    private var resets = 0
    /// The cover file of the Book shown, looked up once per Book.
    private var cover: (bookID: String, url: URL?)?

    /// How far the position may drift from where the system extrapolates it before it's sent again, in seconds.
    /// Playing along isn't sent (the system extrapolates from the last snapshot); seeks and skips are.
    public static let jumpTolerance = 1.0

    public init(player: Player, center: any NowPlayingCenter, covers: CoverFiles?, clock: any Clock) {
        self.player = player
        self.center = center
        self.covers = covers
        self.clock = clock
        resets = player.mediaServicesResets
        center.onCommand = { [weak self] command in self?.handle(command) }
    }

    /// Follows the player until cancelled.
    public func follow() async {
        let player = player
        let changes = Observations { PlayerReading(player) }
        for await reading in changes {
            update(reading)
        }
    }

    private func update(_ reading: PlayerReading) {
        if reading.resets != resets {
            resets = reading.resets
            center.reset()
            hasShown = false
        }
        let state = state(for: reading)
        guard !hasShown || !Self.isSame(state, as: shown) else { return }
        hasShown = true
        shown = state
        center.show(state)
    }

    /// Whether `new` shows what `old` shows, with the position where the system would have extrapolated it.
    private static func isSame(_ new: NowPlayingState?, as old: NowPlayingState?) -> Bool {
        guard let new, let old else { return new == nil && old == nil }
        guard new.item == old.item, new.controls == old.controls, new.playback.status == old.playback.status,
            new.playback.speed == old.playback.speed
        else { return false }
        return abs(new.playback.elapsed - old.playback.extrapolated(to: new.playback.date)) <= jumpTolerance
    }

    private func coverURL(ofBook bookID: String) -> URL? {
        if let cover, cover.bookID == bookID { return cover.url }
        let url = covers.flatMap { $0.exists(forBook: bookID) ? $0.url(forBook: bookID) : nil }
        cover = (bookID, url)
        return url
    }

    private func state(for reading: PlayerReading) -> NowPlayingState? {
        guard let book = reading.book else { return nil }
        let chapters = book.chapters
        let index = chapters.index(at: reading.position)
        let chapter = chapters.chapters[index]
        let times = PlaybackTimes(position: reading.position, chapters: chapters, bookDuration: book.duration)
        let item = NowPlayingItem(
            bookID: book.id,
            title: chapter.title,
            subtitle: book.authorName.isEmpty ? book.title : "\(book.title) · \(book.authorName)",
            narratorName: book.narratorName.isEmpty ? nil : book.narratorName,
            chapterNumber: index + 1,
            chapterCount: chapters.count,
            chapterStart: chapter.start,
            duration: chapter.duration,
            coverURL: coverURL(ofBook: book.id))
        let status: NowPlayingPlayback.Status =
            switch reading.state {
            case .playing: .playing(rate: reading.speed)
            case .loading: .loading
            case .paused, .idle: .paused
            }
        let playback = NowPlayingPlayback(
            status: status, speed: reading.speed, elapsed: times.chapterElapsed, date: clock.now)
        let controls = NowPlayingControls(
            skipBack: reading.skipBack.seconds, skipForward: reading.skipForward.seconds,
            speeds: PlaybackSpeed.presets)
        return NowPlayingState(item: item, playback: playback, controls: controls)
    }

    private func handle(_ command: NowPlayingCommand) {
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .togglePlayPause: player.togglePlayPause()
        // The interval the system passes is ignored: the setting always wins.
        case .skipBack, .previousTrack: player.skipBack()
        case .skipForward, .nextTrack: player.skipForward()
        case .seek(let time):
            // Relative to the Chapter the listener saw when scrubbing.
            guard let item = shown?.item, player.book?.id == item.bookID else { return }
            player.seek(to: item.chapterStart + min(max(time, 0), item.duration))
        case .changeSpeed(let speed): player.setSpeed(speed)
        }
    }
}

/// What Now Playing follows of the player, read in one go (so `Observations` tracks all of it).
private struct PlayerReading: Sendable {
    let book: BookDetail?
    let state: Player.State
    let position: Double
    let speed: Double
    let skipBack: SkipInterval
    let skipForward: SkipInterval
    let resets: Int

    init(_ player: Player) {
        book = player.book
        state = player.state
        position = player.position
        speed = player.speed
        skipBack = player.skipBackInterval
        skipForward = player.skipForwardInterval
        resets = player.mediaServicesResets
    }
}
