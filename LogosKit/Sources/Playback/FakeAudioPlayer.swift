import Foundation

/// An ``AudioPlayer`` for tests: nothing moves until the test says so.
///
/// `load` checks the files exist (like the real one failing to open them). Time moves only through ``advance(to:)``
/// and ``advance(by:)``, which fire the time observers and any boundaries crossed (only while playing). Seeks
/// finish at once unless ``holdsSeeks`` is set; then ``finishSeeks()`` completes them. Loads finish at once unless
/// ``holdsLoads`` is set: then, like the real player, the new timeline is in place (at 0) at once but `load` returns
/// only on ``finishLoads()``.
public final class FakeAudioPlayer: AudioPlayer {
    public struct LoadError: Error, Hashable {
        public let missing: URL
    }

    /// The files of the current timeline, or `nil` if nothing is loaded.
    public private(set) var loadedFiles: [URL]?
    /// How many times a timeline was loaded.
    public private(set) var loadCount = 0
    public private(set) var isPlaying = false
    public var rate: Float = 1
    public private(set) var currentTime: Double = 0
    /// Every seek asked for, in order.
    public private(set) var seeks: [Double] = []
    /// When set, seeks wait for ``finishSeeks()``.
    public var holdsSeeks = false
    /// When set, `play()` reports ``AudioPlayerEvent/startedPlaying`` at once.
    public var reportsStartedPlaying = true
    public var onEvent: ((AudioPlayerEvent) -> Void)?

    private var timeObservers: [UUID: (Double) -> Void] = [:]
    private var boundaryObservers: [UUID: (times: [Double], handler: (Double) -> Void)] = [:]
    private var heldSeeks: [CheckedContinuation<Void, Never>] = []
    private var heldLoads: [CheckedContinuation<Void, Never>] = []

    /// When set, loads wait for ``finishLoads()`` (after the timeline is swapped in).
    public var holdsLoads = false

    /// When set, `load` fails as if the player couldn't open the files.
    public var failsToLoad = false

    public init() {}

    public func load(_ files: [URL]) async throws {
        isPlaying = false
        if failsToLoad, let first = files.first {
            loadedFiles = nil
            throw LoadError(missing: first)
        }
        for file in files where !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            loadedFiles = nil
            throw LoadError(missing: file)
        }
        loadedFiles = files
        loadCount += 1
        currentTime = 0
        if holdsLoads {
            await withCheckedContinuation { heldLoads.append($0) }
        }
    }

    /// Completes the loads held by ``holdsLoads``.
    public func finishLoads() async {
        let held = heldLoads
        heldLoads = []
        for load in held { load.resume() }
        for _ in 0..<20 { await Task.yield() }
    }

    public func unload() {
        isPlaying = false
        loadedFiles = nil
        currentTime = 0
    }

    /// How many times the player was rebuilt (after a media-services reset).
    public private(set) var rebuildCount = 0

    public func rebuild() {
        rebuildCount += 1
        unload()
    }

    public func play() {
        guard loadedFiles != nil else { return }
        isPlaying = true
        if reportsStartedPlaying { onEvent?(.startedPlaying) }
    }

    public func pause() {
        isPlaying = false
    }

    public func seek(to time: Double) async {
        seeks.append(time)
        if holdsSeeks {
            // Like the real player, it reports where it was until the seek lands.
            await withCheckedContinuation { heldSeeks.append($0) }
        }
        currentTime = time
        for observer in timeObservers.values { observer(currentTime) }
    }

    /// Completes the seeks held by ``holdsSeeks``.
    public func finishSeeks() async {
        let held = heldSeeks
        heldSeeks = []
        for seek in held { seek.resume() }
        for _ in 0..<20 { await Task.yield() }
    }

    public func observeTime(every interval: Double, _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        let id = UUID()
        timeObservers[id] = handler
        return AudioPlayerObservation { [weak self] in self?.timeObservers[id] = nil }
    }

    public func observeBoundaries(_ times: [Double], _ handler: @escaping (Double) -> Void) -> AudioPlayerObservation {
        let id = UUID()
        boundaryObservers[id] = (times, handler)
        return AudioPlayerObservation { [weak self] in self?.boundaryObservers[id] = nil }
    }

    /// How many time and boundary observers are registered.
    public var observerCount: Int { timeObservers.count + boundaryObservers.count }

    /// Plays on to `time` (only while playing), reporting it to the time observers and firing boundaries crossed.
    public func advance(to time: Double) {
        guard isPlaying, time >= currentTime else { return }
        let from = currentTime
        currentTime = time
        for observer in boundaryObservers.values {
            for boundary in observer.times where boundary > from && boundary <= time {
                observer.handler(boundary)
            }
        }
        for observer in timeObservers.values { observer(time) }
    }

    public func advance(by seconds: Double) {
        advance(to: currentTime + seconds)
    }

    /// Plays to the end of the timeline at `time`: pauses there and reports it.
    public func playToEnd(at time: Double) {
        advance(to: time)
        isPlaying = false
        onEvent?(.playedToEnd)
    }

    /// The decoder fails at the current time: the player stops and reports it.
    public func failToDecode() {
        isPlaying = false
        onEvent?(.decodeFailed(at: currentTime))
    }
}
