// PROTOTYPE — throwaway. Drives one engine, measures it, and publishes it to the iOS 27 Now Playing framework.
// Everything it learns goes into `log` (copyable from the player screen) so results can be pasted into the ticket.

import AVFoundation
import NowPlaying
import Observation

@Observable
final class PlayerModel: MediaSessionRepresentable {
    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
    }

    let book: Book
    private(set) var engineKind: EngineKind
    private(set) var engine: Engine
    private(set) var currentTime = 0.0
    private(set) var fileIndex = 0
    private(set) var chapterIndex = 0
    private(set) var status = "loading"
    private(set) var isPlaying = false
    private(set) var isBusy = false
    private(set) var log: [LogLine] = []
    var rate: Float = 1.0 { didSet { applyRate() } }
    var algorithm: AVAudioTimePitchAlgorithm = .timeDomain { didSet { engine.setAlgorithm(algorithm) } }
    var chapterScopedLockScreen = true { didSet { publishContent(); publishSnapshot() } }

    private let detector: GapDetector?
    private var session: MediaSession<PlayerModel>?
    private var ticker: Task<Void, Never>?
    private var playRequestedAt: ContinuousClock.Instant?
    private var lastStatus: AVPlayer.TimeControlStatus?
    private var lastTickTime = 0.0
    private var isSeeking = false
    /// Book times where a seek left or landed; the tap sees ramps there, which aren't file-boundary gaps.
    private var seekMarks: [Double] = []
    private var ignoredDetectorEvents = 0

    // MARK: Now Playing (MediaSessionRepresentable)

    nonisolated let id = "logos-prototype-player"
    private(set) var content: (any MediaContentRepresentable)?
    private(set) var playbackSnapshot: MediaPlaybackSnapshot?

    var commands: [MediaCommand] {
        [
            .play { [weak self] in self?.play() },
            .pause { [weak self] in self?.pause() },
            .togglePlayPause { [weak self] in self?.togglePlay() },
            .skipBackward(preferredIntervals: [15]) { [weak self] i in await self?.skip(-i) },
            .skipForward(preferredIntervals: [30]) { [weak self] i in await self?.skip(i) },
            .seekToPosition { [weak self] p in
                guard let self else { return }
                let base = chapterScopedLockScreen ? book.effectiveChapters[chapterIndex].start : 0
                note("lock screen: seek to \(clock(p)) (\(chapterScopedLockScreen ? "in Chapter" : "in Book"))")
                await seek(to: base + p)
            },
            .changePlaybackRate(supported: [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]) { [weak self] r in
                self?.note(String(format: "lock screen: speed %.2f×", r))
                self?.rate = r
            },
        ]
    }

    init(book: Book, engine kind: EngineKind) {
        self.book = book
        self.engineKind = kind
        self.engine = kind == .composition ? CompositionEngine() : QueueEngine()
        self.detector = book.hasToneChannel == true ? GapDetector() : nil
        note("Book: \(book.title) — \(book.tracks.count) file(s), \(book.effectiveChapters.count) Chapter(s), \(clock(book.duration))")
        if detector == nil { note("(no tone channel: gap detector off, listen instead)") }
    }

    // MARK: Lifecycle

    func start() async {
        session = MediaSession(self)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await load(at: 0)
    }

    func stop() {
        ticker?.cancel()
        engine.tearDown()
        session = nil
    }

    private func load(at position: Double) async {
        isBusy = true
        defer { isBusy = false }
        status = "loading"
        note("[\(engineKind.rawValue)] cold load…")
        let started = ContinuousClock.now
        do {
            engine.setAlgorithm(algorithm)
            try await engine.load(book, detector: detector) { [weak self] in self?.note($0) }
            note("[\(engineKind.rawValue)] ready to play after \(ms(since: started))")
            if position > 0 { await seek(to: position) }
            status = "ready"
        } catch {
            status = "failed"
            note("✖︎ load failed: \(error.localizedDescription)")
        }
        publishContent()
        publishSnapshot()
    }

    func switchEngine(to kind: EngineKind) async {
        guard kind != engineKind, !isBusy else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        engine.tearDown()
        isPlaying = false
        engineKind = kind
        engine = kind == .composition ? CompositionEngine() : QueueEngine()
        note("— switched to \(kind.rawValue) at \(clock(position)) —")
        await load(at: position)
        if wasPlaying { play() }
    }

    // MARK: Transport

    func play() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            note("✖︎ audio session: \(error.localizedDescription)")
        }
        playRequestedAt = .now
        engine.player.defaultRate = rate
        engine.player.play()
        isPlaying = true
        publishSnapshot()
        Task {
            guard let session, !session.isApplicationPrimary else { return }
            do {
                try await session.requestToBecomeApplicationPrimary()
                try await session.requestToBecomeSystemPrimary()
                note("Now Playing: session is primary")
            } catch {
                note("✖︎ Now Playing: \(error)")
            }
        }
    }

    func pause() {
        engine.player.pause()
        isPlaying = false
        publishSnapshot()
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func skip(_ seconds: Double) async {
        await seek(to: currentTime + seconds)
    }

    /// Seeks and logs where it actually landed and how long it took.
    @discardableResult
    func seek(to target: Double, quiet: Bool = false) async -> (error: Double, latency: Duration) {
        let t = min(max(0, target), book.duration - 0.5)
        let fromFile = engine.currentFileIndex
        seekMarks += [engine.currentTime, t]
        isSeeking = true
        let started = ContinuousClock.now
        let finished = await engine.seek(to: t)
        let latency = ContinuousClock.now - started
        isSeeking = false
        tick()
        let landed = engine.currentTime
        if !quiet {
            let crossFile = book.trackIndex(at: t) != fromFile ? " cross-file" : ""
            note(String(format: "seek%@ → %@: landed %@ (%+.3f s) in %@%@", crossFile, clock(t), clock(landed), landed - t,
                        ms(since: started), finished ? "" : " [not finished]"))
        }
        publishSnapshot()
        return (landed - t, latency)
    }

    func seekToChapter(_ index: Int) async {
        let c = book.effectiveChapters[index]
        note("Chapter \(index + 1) “\(c.title)” starts \(clock(c.start)) → file \(book.trackIndex(at: c.start) + 1)")
        await seek(to: c.start)
    }

    /// Jumps to `lead` seconds before the next (or previous) file boundary, so the boundary can be heard.
    func jumpToBoundary(forward: Bool, lead: Double = 4) async {
        let starts = book.tracks.map(\.startOffset).dropFirst()
        let now = currentTime
        let boundary = forward ? starts.first { $0 > now + lead + 0.5 } : starts.last { $0 < now - lead - 0.5 }
        guard let boundary else { note("no \(forward ? "next" : "previous") file boundary"); return }
        note("→ \(Int(lead)) s before the file boundary at \(clock(boundary)) (listen for the tone in the right ear)")
        await seek(to: boundary - lead)
        if !isPlaying { play() }
    }

    private func applyRate() {
        engine.player.defaultRate = rate
        if isPlaying { engine.player.rate = rate }
        publishSnapshot()
    }

    // MARK: Seek test

    /// Seeks around the Book at 1×, 1.5× and 2× and measures landing error, latency and drift after 1 s of play.
    func runSeekTest() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let savedRate = rate
        var targets = book.effectiveChapters.prefix(8).map(\.start).map { $0 + 0.0 }
        targets += book.tracks.dropFirst().prefix(6).flatMap { [$0.startOffset - 1.5, $0.startOffset + 0.25] }
        var rng = SystemRandomNumberGenerator()
        targets += (0..<4).map { _ in Double.random(in: 0..<(book.duration - 5), using: &rng) }
        targets.append(book.duration * 0.9)
        targets.append(1)  // a long backward jump, cross-file for multi-file Books
        note("── seek test: \(targets.count) targets × 3 speeds ──")
        var worstError = 0.0, worstDrift = 0.0
        var latencies: [Double] = []
        for r: Float in [1.0, 1.5, 2.0] {
            rate = r
            for target in targets {
                pause()
                let (error, latency) = await seek(to: target, quiet: true)
                latencies.append(Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000)
                let before = engine.currentTime
                play()
                try? await Task.sleep(for: .seconds(1))
                let advanced = engine.currentTime - before
                let drift = advanced - Double(r)  // how far off 1 s of wall time at rate r
                worstError = max(worstError, abs(error))
                worstDrift = max(worstDrift, abs(drift))
                note(String(format: "  %.2f× → %@  err %+.3f s, %3.0f ms, played %.2f s in 1 s (Δ %+.2f)", r, clock(target), error,
                            latencies.last!, advanced, drift))
            }
        }
        pause()
        rate = savedRate
        latencies.sort()
        note("(\(ignoredDetectorEvents) gap-detector hits so far were next to a seek and ignored)")
        note(String(format: "── seek test done: worst landing error %.3f s, latency median %.0f ms / max %.0f ms, worst drift %.2f s ──",
                    worstError, latencies[latencies.count / 2], latencies.last ?? 0, worstDrift))
        note("   (drift includes start-up time after each seek; compare engines, not absolute values)")
    }

    /// Scripted pass for `-autorun`: cross every file boundary while playing, then the seek test.
    func autorun() async {
        while status == "loading" { try? await Task.sleep(for: .milliseconds(50)) }
        play()
        try? await Task.sleep(for: .seconds(2))
        for boundary in book.tracks.dropFirst().map(\.startOffset) {
            note("autorun: crossing \(clock(boundary))")
            await seek(to: boundary - 2)
            try? await Task.sleep(for: .seconds(3.5))
        }
        pause()
        await runSeekTest()
        print("AUTORUN DONE")
    }

    // MARK: Ticking

    private func tick() {
        let player = engine.player
        let t = engine.currentTime
        let file = engine.currentFileIndex
        let status = player.timeControlStatus
        if file != fileIndex {
            let jump = t - lastTickTime
            if !isSeeking && abs(jump) < 2 {  // a natural transition, not a seek
                note(String(format: "▸ file %d → %d at %@ (Book time moved %+.2f s across the boundary)", fileIndex + 1, file + 1,
                            clock(t), jump))
            }
            fileIndex = file
        }
        if status != lastStatus {
            if status == .playing, let requested = playRequestedAt {
                note("play → playing in \(ms(since: requested))")
                playRequestedAt = nil
            }
            if status == .waitingToPlayAtSpecifiedRate, let reason = player.reasonForWaitingToPlay {
                note("waiting: \(reason.rawValue)")
            }
            lastStatus = status
        }
        if let detector {
            for e in detector.drain() {
                if seekMarks.contains(where: { e.bookTime > $0 - 0.4 && e.bookTime < $0 + 1.6 }) {  // the tap runs ahead of the playhead
                    ignoredDetectorEvents += 1
                    continue
                }
                let nearest = book.tracks.map(\.startOffset).dropFirst().min { abs($0 - e.bookTime) < abs($1 - e.bookTime) }
                let where_ = nearest.map { String(format: " — %+.3f s from the file boundary at %@", e.bookTime - $0, clock($0)) } ?? ""
                note("⚠︎ \(clock(e.bookTime)): \(e.text)\(where_)")
            }
        }
        let chapter = book.chapterIndex(at: t)
        if chapter != chapterIndex {
            chapterIndex = chapter
            publishContent()
            publishSnapshot()
        }
        currentTime = t
        lastTickTime = t
        self.status = status == .playing ? "playing" : status == .paused ? "paused" : "waiting"
        // Player stopped by itself (end of Book, interruption): keep the lock screen honest.
        if isPlaying && status == .paused && playRequestedAt == nil {
            isPlaying = false
            publishSnapshot()
        }
    }

    // MARK: Publishing

    private func publishContent() {
        let chapters = book.effectiveChapters
        let c = chapters[chapterIndex]
        let duration = chapterScopedLockScreen ? c.end - c.start : book.duration
        var bookContent = BookContent(id: book.id, title: chapterScopedLockScreen ? c.title : book.title, authorName: book.author,
                                      duration: .finite(duration), artwork: nil)
        bookContent.chapter = (current: chapterIndex + 1, total: chapters.count)
        content = bookContent
    }

    private func publishSnapshot() {
        let base = chapterScopedLockScreen ? book.effectiveChapters[chapterIndex].start : 0
        playbackSnapshot = MediaPlaybackSnapshot(state: isPlaying ? .playing(rate: rate) : .paused, defaultPlaybackRate: rate,
                                                 elapsedTime: engine.currentTime - base, timestamp: .now)
    }

    func note(_ text: String) {
        let stamp = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        log.append(LogLine(text: "\(stamp) \(text)"))
        if Autorun.isActive { print("LOG \(text)") }
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }
}
