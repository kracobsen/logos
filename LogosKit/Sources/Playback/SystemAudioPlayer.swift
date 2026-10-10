import AVFoundation
import Foundation

/// The real ``AudioPlayer``: one `AVPlayer` playing an `AVMutableComposition` of the Book's files inserted back to
/// back with precise timing, so player time is Book time and there are no gaps at file boundaries (prototype #12).
///
/// The files are local, so `automaticallyWaitsToMinimizeStalling` is off and seeks are exact. The audio session is
/// `.playback` with `.spokenAudio` (the app has the background audio mode).
public final class SystemAudioPlayer: AudioPlayer {
    public enum LoadError: Error, Hashable {
        case cannotBuildTimeline
        /// The file has no audio track.
        case noAudio(URL)
        /// The timeline failed to become ready.
        case notReady(String)
    }

    /// Made on first use rather than in `init`: the app makes its player during launch, and creating an `AVPlayer`
    /// there cost 10–60 ms of the cold launch (simulator). Dropped by ``rebuild()`` after a media-services reset.
    private var madePlayer: AVPlayer?
    private var player: AVPlayer {
        if let madePlayer { return madePlayer }
        let made = AVPlayer()
        madePlayer = made
        setUp(made)
        for (id, var observer) in timeObservers {
            observer.token = observer.add(made)
            timeObservers[id] = observer
        }
        return made
    }
    private var itemObservers: [any NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// The time and boundary observers, kept so ``rebuild()`` can add them to the new `AVPlayer`.
    private var timeObservers: [UUID: TimeObserver] = [:]
    private var hasConfiguredSession = false
    public var onEvent: ((AudioPlayerEvent) -> Void)?

    private struct TimeObserver {
        /// Adds the observer to a player, returning its token.
        let add: (AVPlayer) -> Any
        /// `nil` until the `AVPlayer` is made.
        var token: Any?
    }

    public var rate: Float = 1 {
        didSet {
            guard let madePlayer else { return }  // it's set up with the rate when it's made
            madePlayer.defaultRate = rate
            if madePlayer.rate != 0 { madePlayer.rate = rate }
        }
    }

    /// Keeps sped-up speech natural: `.timeDomain` is Apple's speech algorithm, the one other speech apps use.
    /// `.spectral` is meant for music and makes speech sound tinny.
    public static let timePitchAlgorithm = AVAudioTimePitchAlgorithm.timeDomain

    /// The time-pitch algorithm of what's loaded (nil when nothing is).
    public var pitchAlgorithm: AVAudioTimePitchAlgorithm? { madePlayer?.currentItem?.audioTimePitchAlgorithm }

    public init() {}

    private func setUp(_ player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.defaultRate = rate
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            @Sendable [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in self?.onEvent?(.startedPlaying) }
        }
    }

    /// After a media-services reset every audio object is dead: drop the `AVPlayer` for a new one with the same
    /// observers, and set the session category again on the next load.
    public func rebuild() {
        unload()
        for (id, var observer) in timeObservers {
            if let token = observer.token { madePlayer?.removeTimeObserver(token) }
            observer.token = nil
            timeObservers[id] = observer
        }
        timeControlObservation = nil
        madePlayer = nil  // a new one, with the same observers, on next use
        hasConfiguredSession = false
    }

    public var currentTime: Double {
        guard let madePlayer else { return 0 }
        let seconds = madePlayer.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    public func load(_ files: [URL]) async throws {
        configureSessionIfNeeded()
        player.pause()
        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw LoadError.cannotBuildTimeline }
        var cursor = CMTime.zero
        for file in files {
            let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw LoadError.noAudio(file)
            }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = Self.timePitchAlgorithm
        replaceItem(with: item)
        try await Self.waitUntilReady(item)
    }

    public func unload() {
        guard let madePlayer else { return }
        madePlayer.pause()
        replaceItem(with: nil)
    }

    public func play() {
        activateSession()
        player.defaultRate = rate
        player.play()
    }

    public func pause() {
        madePlayer?.pause()
    }

    public func seek(to time: Double) async {
        let target = CMTime(seconds: time, preferredTimescale: 44_100)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func observeTime(every interval: Double, _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        nonisolated(unsafe) let handler = handler
        return addTimeObserver { player in
            player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main
            ) { @Sendable time in
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                MainActor.assumeIsolated { handler(seconds) }
            }
        }
    }

    public func observeBoundaries(_ times: [Double], _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        guard !times.isEmpty else { return AudioPlayerObservation {} }
        nonisolated(unsafe) let handler = handler
        let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 44_100)) }
        return addTimeObserver { [weak self] player in
            player.addBoundaryTimeObserver(forTimes: values, queue: .main) { @Sendable [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // AVPlayer doesn't say which boundary; it's the one closest to now.
                    let now = self.currentTime
                    let crossed = times.min { abs($0 - now) < abs($1 - now) } ?? now
                    handler(crossed)
                }
            }
        }
    }

    private func addTimeObserver(_ add: @escaping (AVPlayer) -> Any) -> AudioPlayerObservation {
        let id = UUID()
        timeObservers[id] = TimeObserver(add: add, token: madePlayer.map(add))
        return AudioPlayerObservation { [weak self] in
            guard let self, let observer = self.timeObservers.removeValue(forKey: id) else { return }
            if let token = observer.token { self.madePlayer?.removeTimeObserver(token) }
        }
    }

    // MARK: - Private

    private func replaceItem(with item: AVPlayerItem?) {
        for observer in itemObservers { NotificationCenter.default.removeObserver(observer) }
        itemObservers = []
        itemStatusObservation = nil
        player.replaceCurrentItem(with: item)
        guard let item else { return }
        let center = NotificationCenter.default
        itemObservers.append(
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
                @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.playedToEnd) }
            })
        itemObservers.append(
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                @Sendable [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                let description = String(describing: error)
                MainActor.assumeIsolated { self?.failed(description) }
            })
        itemStatusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            guard item.status == .failed else { return }
            let description = String(describing: item.error)
            Task { @MainActor in self?.failed(description) }
        }
    }

    /// Playing stopped with an error mid-play. The xHE-AAC bug (FB22340742) shows up as -11821 "Cannot Decode";
    /// every mid-play failure is reported as a decode failure so the engine reloads and carries on (or gives up).
    private func failed(_ description: String) {
        guard madePlayer?.currentItem != nil else { return }
        log.error("Playing failed: \(description, privacy: .public)")
        onEvent?(.decodeFailed(at: currentTime))
    }

    private static func waitUntilReady(_ item: AVPlayerItem) async throws {
        let statuses = AsyncStream<AVPlayerItem.Status> { continuation in
            let observation = item.observe(\.status, options: [.initial, .new]) { @Sendable item, _ in
                continuation.yield(item.status)
            }
            continuation.onTermination = { _ in observation.invalidate() }
        }
        for await status in statuses {
            switch status {
            case .readyToPlay: return
            case .failed: throw LoadError.notReady(String(describing: item.error))
            default: continue
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !hasConfiguredSession else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            hasConfiguredSession = true
        } catch {
            log.error("Couldn't set the audio session category: \(String(describing: error), privacy: .public)")
        }
    }

    private func activateSession() {
        configureSessionIfNeeded()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Couldn't activate the audio session: \(String(describing: error), privacy: .public)")
        }
    }
}
