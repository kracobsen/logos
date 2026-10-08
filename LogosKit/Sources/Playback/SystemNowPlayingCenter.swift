import Foundation
import NowPlaying
import Observation

/// The real Now Playing: one `MediaSession` (iOS 27's NowPlaying framework; MediaPlayer is never used) describing the
/// loaded Book as `BookContent`, with `MediaCommand`s for the controls.
///
/// The framework observes this `@Observable` object, so the system updates whenever ``show(_:)`` stores a new state.
/// The spec wants the Chapter name as the title and "Book title · author" as the subtitle, so `BookContent`'s title
/// and author carry those; the duration and elapsed time are the Chapter's.
@Observable
public final class SystemNowPlayingCenter: NowPlayingCenter, MediaSessionRepresentable {
    nonisolated public let id = "logos.player"
    @ObservationIgnored public var onCommand: ((NowPlayingCommand) -> Void)?
    private(set) var state: NowPlayingState?
    @ObservationIgnored private var session: MediaSession<SystemNowPlayingCenter>?

    public init() {}

    public func show(_ state: NowPlayingState?) {
        self.state = state
        guard state != nil, session == nil else { return }
        // Created once there is something to show, so a launch with nothing loaded claims nothing.
        let session = MediaSession(self)
        self.session = session
        Task {
            do {
                try await session.requestToBecomeApplicationPrimary()
            } catch {
                log.error("Now Playing session not primary: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The media services were reset, taking the system's side of the session with them: a new session is made on
    /// the next ``show(_:)``.
    public func reset() {
        session = nil
    }

    // MARK: - MediaSessionRepresentable

    public var content: (any MediaContentRepresentable)? {
        state.map { Self.content(for: $0.item) }
    }

    public var playbackSnapshot: MediaPlaybackSnapshot? {
        guard let playback = state?.playback else { return nil }
        return Self.snapshot(for: playback)
    }

    public var commands: [MediaCommand] {
        guard let controls = state?.controls else { return [] }
        return [
            .play { [weak self] in self?.onCommand?(.play) },
            .pause { [weak self] in self?.onCommand?(.pause) },
            .togglePlayPause { [weak self] in self?.onCommand?(.togglePlayPause) },
            .skipBackward(preferredIntervals: [controls.skipBack]) { [weak self] _ in self?.onCommand?(.skipBack) },
            .skipForward(preferredIntervals: [controls.skipForward]) { [weak self] _ in
                self?.onCommand?(.skipForward)
            },
            .previous { [weak self] in self?.onCommand?(.previousTrack) },
            .next { [weak self] in self?.onCommand?(.nextTrack) },
            .seekToPosition { [weak self] time in self?.onCommand?(.seek(to: time)) },
            .changePlaybackRate(supported: controls.speeds.map(Float.init)) { [weak self] rate in
                self?.onCommand?(.changeSpeed(Double(rate)))
            },
        ]
    }

    // MARK: - Mapping

    static func content(for item: NowPlayingItem) -> BookContent {
        var content = BookContent(
            id: item.bookID,
            title: item.title,
            authorName: item.subtitle,
            narratorName: item.narratorName,
            duration: .finite(item.duration),
            artwork: item.coverURL.map { artwork(bookID: item.bookID, file: $0) })
        content.chapter = (current: item.chapterNumber, total: item.chapterCount)
        // The title and author hold the Chapter and "Book · author", which aren't a Book to suggest.
        content.isExcludedFromSuggestions = true
        return content
    }

    static func snapshot(for playback: NowPlayingPlayback) -> MediaPlaybackSnapshot {
        let state: MediaPlaybackSnapshot.PlaybackState =
            switch playback.status {
            case .loading: .buffering
            case .paused: .paused
            case .playing(let rate): .playing(rate: Float(rate))
            }
        return MediaPlaybackSnapshot(
            state: state, defaultPlaybackRate: Float(playback.speed), elapsedTime: playback.elapsed,
            timestamp: playback.date)
    }

    /// The cover, read from its file when the system asks for it (off the main actor).
    nonisolated static func artwork(bookID: String, file: URL) -> Artwork {
        Artwork(id: bookID) { _ in
            try ArtworkRepresentation(data: Data(contentsOf: file))
        }
    }
}
