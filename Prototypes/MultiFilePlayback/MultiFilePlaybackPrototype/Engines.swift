// PROTOTYPE — throwaway. The two contenders, behind one tiny surface so the player screen can swap them.
//
//   Composition · every file's audio inserted back to back into one AVMutableComposition, played by one AVPlayer.
//                 Book time *is* player time. Needs every file loaded (precise timing) before it can play.
//   Queue       · an AVQueuePlayer with one item per file and an offset table from the Server's track startOffsets.
//                 Book time = offset[current file] + item time. A seek into another file rebuilds the queue.

import AVFoundation

enum EngineKind: String, CaseIterable, Identifiable {
    case composition = "Composition"
    case queue = "Queue"
    var id: String { rawValue }
}

protocol Engine: AnyObject {
    var kind: EngineKind { get }
    var player: AVPlayer { get }
    /// Book time, in seconds.
    var currentTime: Double { get }
    var currentFileIndex: Int { get }
    /// Loads `book` and returns once the player is ready to play.
    func load(_ book: Book, detector: GapDetector?, log: @escaping (String) -> Void) async throws
    /// Seeks to Book time `time`; returns once the seek has completed.
    func seek(to time: Double) async -> Bool
    func setAlgorithm(_ algorithm: AVAudioTimePitchAlgorithm)
    func tearDown()
}

enum EngineError: LocalizedError {
    case noAudioTrack(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let f): "No audio track in \(f)"
        case .failed(let m): m
        }
    }
}

private func preciseAsset(_ url: URL) -> AVURLAsset {
    AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
}

private func waitUntilReady(_ item: AVPlayerItem) async throws {
    while item.status == .unknown { try await Task.sleep(for: .milliseconds(5)) }
    if item.status == .failed { throw EngineError.failed(item.error?.localizedDescription ?? "item failed") }
}

private let exact = CMTime.zero

// MARK: - Composition

final class CompositionEngine: Engine {
    let kind = EngineKind.composition
    let player = AVPlayer()
    private var fileStarts: [Double] = []  // actual start of each file on the composition timeline
    private var algorithm: AVAudioTimePitchAlgorithm = .timeDomain

    var currentTime: Double { player.currentTime().seconds }
    var currentFileIndex: Int { fileStarts.lastIndex { $0 <= currentTime + 0.001 } ?? 0 }

    func load(_ book: Book, detector: GapDetector?, log: @escaping (String) -> Void) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EngineError.failed("could not add composition track")
        }
        var cursor = CMTime.zero
        var drift = 0.0
        fileStarts = []
        for (i, t) in book.tracks.enumerated() {
            let started = ContinuousClock.now
            let asset = preciseAsset(book.url(of: t))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw EngineError.noAudioTrack(t.file) }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: cursor)
            fileStarts.append(cursor.seconds)
            let actual = range.duration.seconds
            drift = cursor.seconds + actual - (t.startOffset + t.duration)
            if book.tracks.count <= 12 || i < 3 || i == book.tracks.count - 1 {
                log(String(format: "  file %d: loaded in %@, duration %.3f s (Server %.3f, Δ %+.3f), placed at %@ (Server %@)",
                           i + 1, ms(since: started), actual, t.duration, actual - t.duration, clock(cursor.seconds), clock(t.startOffset)))
            }
            cursor = cursor + range.duration
        }
        log(String(format: "  composition length %@ vs Server %@ — drift at end %+.3f s", clock(cursor.seconds), clock(book.duration), drift))
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = algorithm
        if let detector { item.audioMix = detector.audioMix(for: track, offset: 0) }
        player.replaceCurrentItem(with: item)
        try await waitUntilReady(item)
    }

    func seek(to time: Double) async -> Bool {
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 44_100), toleranceBefore: exact, toleranceAfter: exact)
    }

    func setAlgorithm(_ algorithm: AVAudioTimePitchAlgorithm) {
        self.algorithm = algorithm
        player.currentItem?.audioTimePitchAlgorithm = algorithm
    }

    func tearDown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

// MARK: - Queue

final class QueueEngine: Engine {
    let kind = EngineKind.queue
    let queue = AVQueuePlayer()
    var player: AVPlayer { queue }
    private var book: Book?
    private var detector: GapDetector?
    private var algorithm: AVAudioTimePitchAlgorithm = .timeDomain
    private var itemIndex: [ObjectIdentifier: Int] = [:]

    var currentFileIndex: Int {
        guard let item = queue.currentItem else { return 0 }
        return itemIndex[ObjectIdentifier(item)] ?? 0
    }

    var currentTime: Double {
        guard let book, let item = queue.currentItem else { return 0 }
        let t = item.currentTime().seconds
        return book.tracks[currentFileIndex].startOffset + (t.isFinite ? t : 0)
    }

    func load(_ book: Book, detector: GapDetector?, log: @escaping (String) -> Void) async throws {
        self.book = book
        self.detector = detector
        queue.actionAtItemEnd = .advance
        rebuild(from: 0)
        guard let first = queue.currentItem else { throw EngineError.failed("empty queue") }
        try await waitUntilReady(first)
        log("  queued \(book.tracks.count) item(s); offsets from the Server's startOffset (no files loaded up front)")
    }

    /// Replaces the queue with items for files `index...`.
    private func rebuild(from index: Int) {
        guard let book else { return }
        queue.removeAllItems()
        itemIndex = [:]
        for i in index..<book.tracks.count {
            let item = AVPlayerItem(asset: preciseAsset(book.url(of: book.tracks[i])))
            item.audioTimePitchAlgorithm = algorithm
            itemIndex[ObjectIdentifier(item)] = i
            queue.insert(item, after: nil)
            if let detector {
                let offset = book.tracks[i].startOffset
                Task {
                    if let track = try? await item.asset.loadTracks(withMediaType: .audio).first {
                        item.audioMix = detector.audioMix(for: track, offset: offset)
                    }
                }
            }
        }
    }

    func seek(to time: Double) async -> Bool {
        guard let book else { return false }
        let target = book.trackIndex(at: time)
        if target != currentFileIndex || queue.currentItem == nil {
            rebuild(from: target)
            if let item = queue.currentItem { try? await waitUntilReady(item) }
        }
        guard let item = queue.currentItem else { return false }
        let local = time - book.tracks[target].startOffset
        return await item.seek(to: CMTime(seconds: local, preferredTimescale: 44_100), toleranceBefore: exact, toleranceAfter: exact)
    }

    func setAlgorithm(_ algorithm: AVAudioTimePitchAlgorithm) {
        self.algorithm = algorithm
        for item in queue.items() { item.audioTimePitchAlgorithm = algorithm }
    }

    func tearDown() {
        queue.pause()
        queue.removeAllItems()
    }
}

func ms(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    return String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
}
