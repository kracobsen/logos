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

    private let player = AVPlayer()
    private var itemObservers: [any NSObjectProtocol] = []
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var hasConfiguredSession = false
    public var onEvent: ((AudioPlayerEvent) -> Void)?

    public var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
        }
    }

    /// Keeps sped-up speech natural. The spec allows `.timeDomain` instead if that sounds better on a device.
    public static let timePitchAlgorithm = AVAudioTimePitchAlgorithm.spectral

    /// The time-pitch algorithm of what's loaded (nil when nothing is).
    public var pitchAlgorithm: AVAudioTimePitchAlgorithm? { player.currentItem?.audioTimePitchAlgorithm }

    public init() {
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            @Sendable [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in self?.onEvent?(.startedPlaying) }
        }
    }

    public var currentTime: Double {
        let seconds = player.currentTime().seconds
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
        player.pause()
        replaceItem(with: nil)
    }

    public func play() {
        activateSession()
        player.defaultRate = rate
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func seek(to time: Double) async {
        let target = CMTime(seconds: time, preferredTimescale: 44_100)
        _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func observeTime(every interval: Double, _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        nonisolated(unsafe) let handler = handler
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600), queue: .main
        ) { @Sendable time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            MainActor.assumeIsolated { handler(seconds) }
        }
        nonisolated(unsafe) let observer = token
        return AudioPlayerObservation { [player] in player.removeTimeObserver(observer) }
    }

    public func observeBoundaries(_ times: [Double], _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        guard !times.isEmpty else { return AudioPlayerObservation {} }
        nonisolated(unsafe) let handler = handler
        let values = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 44_100)) }
        let token = player.addBoundaryTimeObserver(forTimes: values, queue: .main) { @Sendable [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // AVPlayer doesn't say which boundary; it's the one closest to now.
                let now = self.currentTime
                let crossed = times.min { abs($0 - now) < abs($1 - now) } ?? now
                handler(crossed)
            }
        }
        nonisolated(unsafe) let observer = token
        return AudioPlayerObservation { [player] in player.removeTimeObserver(observer) }
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
        guard player.currentItem != nil else { return }
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
