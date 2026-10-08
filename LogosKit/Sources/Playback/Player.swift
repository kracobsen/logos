import Domain
import Foundation
import Observation
import Store

/// The playback engine: plays one downloaded Book at a time from its Download, never from the network.
///
/// It drives an ``AudioPlayer`` whose timeline is the Book's files back to back, so player time is Book time. It
/// publishes the position (about 4 times a second while playing, and at once on a seek), the current Chapter, the
/// rate and the state. The live position is the one thing it exposes directly rather than through the database
/// (ADR 0001): it writes the position, the last-changed time and Finished to the Store every second while playing,
/// and straight away on play, pause, seek, skip, Chapter jump, the end of the Book and going to the background.
@Observable
public final class Player {
    public enum State: Sendable, Hashable {
        /// No Book loaded.
        case idle
        /// Loading ``Player/book``'s files.
        case loading
        case paused
        case playing
    }

    /// Why the last Book couldn't be played.
    public enum Problem: Sendable, Hashable {
        /// The Book isn't (or is no longer) downloaded.
        case notDownloaded
        /// A file couldn't be opened.
        case cannotOpen
        /// A file kept failing to decode, even after reloading.
        case cannotDecode
        /// A file is missing or the wrong size (checked before playing).
        case damagedFiles
    }

    public internal(set) var state: State = .idle
    /// The loaded Book, from the moment it starts loading.
    public private(set) var book: BookDetail?
    /// In Book seconds. Moves to a seek's target straight away.
    public internal(set) var position: Double = 0
    /// Whether the loaded Book is Finished.
    public private(set) var isFinished = false
    /// The global speed playing runs at, one of ``PlaybackSpeed/all``. Kept in the Store across launches.
    public internal(set) var speed: Double
    /// How far ``skipBack()`` moves. Kept in the Store.
    public internal(set) var skipBackInterval: SkipInterval
    /// How far ``skipForward()`` moves. Kept in the Store.
    public internal(set) var skipForwardInterval: SkipInterval
    public private(set) var problem: Problem?
    /// The Download found damaged when the listener played it (or mid-play), until ``dismissDamage()``: the screen
    /// shows "This Download is damaged" with Download again.
    public private(set) var damaged: DamagedDownload?
    /// The Sleep Timer set on the loaded Book, if any (see `Player+SleepTimer.swift`).
    public internal(set) var sleepTimer: SleepTimer?
    /// How many times the media services were reset (and the player rebuilt), so Now Playing can publish again.
    public internal(set) var mediaServicesResets = 0

    /// How often the position is published while playing, in seconds.
    public static let publishInterval = 0.25
    /// How often the position is saved while playing.
    public static let saveInterval = Duration.seconds(1)
    /// How many times a decode failure is worked around by reloading before giving up (FB22340742).
    public static let maxDecodeRetries = 10
    /// How far before a decode failure playing restarts after reloading, in seconds.
    public static let decodeRetryBackoff = 1.0

    @ObservationIgnored let database: AppDatabase
    @ObservationIgnored private let files: DownloadFiles
    @ObservationIgnored let audio: any AudioPlayer
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var timeObservation: AudioPlayerObservation?
    @ObservationIgnored var saving: Task<Void, Never>?
    /// Bumped by every load, so an older load that finishes late is ignored.
    @ObservationIgnored private var loadGeneration = 0
    /// Seeks sent to the player and not finished yet; time reports are stale until they are.
    @ObservationIgnored private var pendingSeeks = 0
    @ObservationIgnored private var decodeRetries = 0
    @ObservationIgnored private var playToAudio: SignpostInterval?
    @ObservationIgnored var sleepTimerObservation: AudioPlayerObservation?
    @ObservationIgnored var stopObservers: [UUID: AsyncStream<PlaybackStop>.Continuation] = [:]
    @ObservationIgnored private let session: (any AudioSession)?
    /// Set when an interruption paused playing, so it may resume when the interruption ends.
    @ObservationIgnored var resumesAfterInterruption = false

    /// `session` reports interruptions, route changes and media-services resets (see Player+AudioSession.swift).
    public init(
        database: AppDatabase, files: DownloadFiles, audio: any AudioPlayer, clock: any Clock,
        session: (any AudioSession)? = nil
    ) {
        self.database = database
        self.files = files
        self.audio = audio
        self.clock = clock
        self.session = session
        let settings = Self.readSettings(database)
        speed = settings.speed
        skipBackInterval = settings.skipBack
        skipForwardInterval = settings.skipForward
        audio.rate = Float(settings.speed)
        timeObservation = audio.observeTime(every: Self.publishInterval) { [weak self] time in
            self?.timePassed(time)
        }
        audio.onEvent = { [weak self] event in self?.handle(event) }
        session?.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// The index of the Chapter the position is in, if a Book is loaded.
    public var chapterIndex: Int? {
        book?.chapters.index(at: position)
    }

    /// The Chapter the position is in, if a Book is loaded.
    public var chapter: Chapter? {
        chapterIndex.flatMap { book?.chapters.chapters[$0] }
    }

    public var isPlaying: Bool { state == .playing }

    // MARK: - Loading

    /// Plays a downloaded Book: the loaded one resumes; another one is loaded at its saved position (the current one
    /// is saved first, with no confirmation) and starts.
    public func play(bookID: String) async {
        if book?.id == bookID, state != .idle {
            play()
            return
        }
        let interval = Signposts.begin(.playOtherBook)
        guard await load(bookID) else {
            interval.end()
            return
        }
        start(signpost: interval)
    }

    /// Plays a downloaded Book from `position` (a Chapter tapped on Book detail), loading it first if it isn't.
    public func play(bookID: String, from position: Double) async {
        if book?.id != bookID || state == .idle {
            let interval = Signposts.begin(.playOtherBook)
            guard await load(bookID) else {
                interval.end()
                return
            }
            seek(to: position)
            start(signpost: interval)
        } else {
            seek(to: position)
            play()
        }
    }

    /// Loads the last-played Book (the most recently changed downloaded one) paused at its position, unless a Book is
    /// loaded already. Never plays. Call it just after launch, once the Library is interactive.
    public func restoreLastPlayed() async {
        guard book == nil else { return }
        let interval = Signposts.begin(.lastPlayedBookReady)
        defer { interval.end() }
        do {
            guard let bookID = try database.lastPlayedBookID() else { return }
            // Not a user action: a damaged Download is marked not downloaded without a notice.
            _ = await load(bookID, reportsDamage: false)
        } catch {
            log.error("Couldn't read the last-played Book: \(String(describing: error), privacy: .public)")
        }
    }

    /// Loads the Book paused at its saved position. Returns whether it's loaded (and no later load replaced it).
    /// A damaged Download (a file missing, the wrong size or not opening) is discarded; `reportsDamage` says whether
    /// to publish it in ``damaged``.
    private func load(_ bookID: String, reportsDamage: Bool = true) async -> Bool {
        pause(because: .switchedBook)
        cancelSleepTimer()
        loadGeneration += 1
        let generation = loadGeneration
        problem = nil
        if reportsDamage { damaged = nil }
        decodeRetries = 0
        let detail: BookDetail
        let saved: BookProgress?
        do {
            guard let found = try database.bookDetail(id: bookID),
                try database.downloadStatus(ofBook: bookID)?.state == .downloaded
            else {
                unload(problem: .notDownloaded)
                return false
            }
            detail = found
            saved = try database.progress(ofBook: bookID)
            guard try database.hasIntactDownload(ofBook: bookID, in: files) else {
                log.error("A Book's Download is damaged: a file is missing or the wrong size")
                unload(problem: .damagedFiles)
                discardDamaged(found, reports: reportsDamage)
                return false
            }
        } catch {
            log.error("Couldn't read a Book to play: \(String(describing: error), privacy: .public)")
            unload(problem: .notDownloaded)
            return false
        }
        book = detail
        isFinished = saved?.isFinished ?? false
        position = min(max(saved?.position ?? 0, 0), detail.duration)
        state = .loading
        do {
            try await audio.load(fileURLs(of: detail))
        } catch {
            guard generation == loadGeneration else { return false }
            log.error("Couldn't open a Book's files: \(String(describing: error), privacy: .public)")
            unload(problem: .cannotOpen)
            discardDamaged(detail, reports: reportsDamage)
            return false
        }
        guard generation == loadGeneration else { return false }
        if position > 0 {
            pendingSeeks += 1
            await audio.seek(to: position)
            pendingSeeks -= 1
            guard generation == loadGeneration else { return false }
        }
        state = .paused
        return true
    }

    /// Stops playing and unloads the Book if it's the one loaded (before its Download is removed). Saves first.
    public func stop(bookID: String) {
        guard book?.id == bookID else { return }
        pause(because: .stopped)
        loadGeneration += 1
        unload(problem: nil)
    }

    /// Follows Downloads until cancelled: when the loaded Book stops being downloaded (however its Download was
    /// removed), it's stopped and saved. Removal paths should still call ``stop(bookID:)`` first.
    public func observeDownloads() async {
        do {
            for try await statuses in database.downloadStatusUpdates() {
                guard let bookID = book?.id, statuses[bookID]?.state != .downloaded else { continue }
                stop(bookID: bookID)
            }
        } catch {
            log.error("Stopped observing Downloads: \(String(describing: error), privacy: .public)")
        }
    }

    /// The Book's Download is damaged: it becomes not downloaded (its files go; its position and Finished stay) and
    /// nothing downloads it again on its own. Call it once the Book is saved and unloaded.
    private func discardDamaged(_ detail: BookDetail, reports: Bool) {
        do {
            try database.discardDamagedDownload(ofBook: detail.id, files: files)
        } catch {
            log.error("Couldn't discard a damaged Download: \(String(describing: error), privacy: .public)")
        }
        if reports {
            damaged = DamagedDownload(bookID: detail.id, title: detail.title, isNotOnServer: detail.isNotOnServer)
        }
    }

    /// The listener has seen the damage notice.
    public func dismissDamage() {
        damaged = nil
    }

    private func unload(problem: Problem?) {
        cancelSleepTimer()
        saving?.cancel()
        saving = nil
        resumesAfterInterruption = false
        audio.unload()
        book = nil
        position = 0
        isFinished = false
        state = .idle
        self.problem = problem
    }

    private func fileURLs(of book: BookDetail) -> [URL] {
        book.tracks.map { files.url(forBook: book.id, relPath: $0.relPath) }
    }

    // MARK: - Controls

    /// Plays the loaded Book from where it is, without rewinding. A Finished Book starts again from 0 and is no
    /// longer Finished.
    public func play() {
        guard book != nil, state == .paused else { return }
        start(signpost: Signposts.begin(.playLoadedBook))
    }

    private func start(signpost: SignpostInterval) {
        guard let book, state == .paused else {
            signpost.end()
            return
        }
        resumesAfterInterruption = false
        if isFinished {
            isFinished = false
            seek(to: 0)
        }
        playToAudio?.end()
        playToAudio = signpost
        audio.play()
        state = .playing
        save()
        saving?.cancel()
        // Sleeps on this (main) actor rather than through `Clock.timer`, so each tick runs in step with the clock.
        let clock = clock
        saving = Task { [weak self] in
            while true {
                do {
                    try await clock.sleep(for: Self.saveInterval)
                } catch {
                    return
                }
                guard let self, self.state == .playing, self.book?.id == book.id else { return }
                if self.pendingSeeks == 0 { self.position = self.audio.currentTime }
                self.save()
            }
        }
    }

    /// Pauses and saves. Does nothing unless playing. Pausing within the Book's last 30 s finishes it.
    public func pause() {
        pause(because: .paused)
    }

    /// Pauses, saves (at `landing`, moving there, if given) and reports the stop. Does nothing unless playing.
    /// Pausing (or landing) within the Book's last 30 s finishes it instead, reported with the same reason.
    func pause(because reason: PlaybackStop.Reason, landingAt landing: Double? = nil) {
        guard let book, state == .playing else { return }
        let stoppedAt = landing ?? (pendingSeeks == 0 ? audio.currentTime : position)
        // The system pausing (an interruption, a lost route) isn't the listener stopping, so it never finishes.
        let isSystemPause = reason == .interrupted || reason == .routeLost
        if !isSystemPause, FinishRule.finishes(at: stoppedAt, duration: book.duration) {
            finish(because: reason)
            return
        }
        audio.pause()
        state = .paused
        saving?.cancel()
        saving = nil
        if let landing {
            seek(to: landing)
        } else {
            if pendingSeeks == 0 { position = audio.currentTime }
            save()
        }
        reportStop(PlaybackStop(bookID: book.id, position: position, reason: reason))
    }

    /// Stops playing and marks the loaded Book Finished, with the position at the end (saved), and clears the Sleep
    /// Timer. Nothing plays next. If it was playing, the stop is reported with `reason`.
    private func finish(because reason: PlaybackStop.Reason) {
        guard let book, state == .paused || state == .playing else { return }
        let wasPlaying = state == .playing
        if wasPlaying { audio.pause() }
        state = .paused
        saving?.cancel()
        saving = nil
        cancelSleepTimer()
        isFinished = true
        seek(to: book.duration)
        if wasPlaying { reportStop(PlaybackStop(bookID: book.id, position: position, reason: reason)) }
    }

    /// Sets or clears Finished by hand (Book detail). Finished stops the Book if it's playing and puts it at the end;
    /// clearing Finished moves it to 0.
    public func setFinished(_ finished: Bool, bookID: String) {
        guard book?.id == bookID, state == .paused || state == .playing else {
            do {
                try database.setFinished(finished, ofBook: bookID, at: clock.now)
            } catch {
                log.error("Couldn't set Finished: \(String(describing: error), privacy: .public)")
            }
            return
        }
        if finished {
            finish(because: .endOfBook)
        } else {
            isFinished = false
            seek(to: 0)
        }
    }

    public func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    /// Moves to `time` (in Book seconds): the position moves at once, the audio follows. Saves.
    public func seek(to time: Double) {
        guard let book, state != .idle else { return }
        let target = min(max(time, 0), book.duration)
        sleepTimerSeeked(to: target)
        position = target
        pendingSeeks += 1
        save()
        let interval = Signposts.begin(.seekToAudio)
        Task {
            await audio.seek(to: target)
            pendingSeeks -= 1
            interval.end()
        }
    }

    /// Skips `seconds` forward (or back, if negative), staying within the Book. Skipping forward into the last 30 s
    /// stops playing and finishes the Book.
    public func skip(by seconds: Double) {
        if seconds > 0, let book, state == .paused || state == .playing,
            FinishRule.finishes(at: position + seconds, duration: book.duration)
        {
            finish(because: .endOfBook)
            return
        }
        seek(to: position + seconds)
    }

    /// Jumps to the start of the Chapter at `index`.
    public func jump(toChapter index: Int) {
        guard let chapters = book?.chapters.chapters, chapters.indices.contains(index) else { return }
        seek(to: chapters[index].start)
    }

    /// The app is going to the background: saves now if playing (a paused Book is already saved).
    public func enteredBackground() {
        guard state == .playing else { return }
        position = audio.currentTime
        save()
    }

    // MARK: - Reports from the player

    private func timePassed(_ time: Double) {
        guard pendingSeeks == 0, state == .playing || state == .paused else { return }
        position = time
    }

    private func handle(_ event: AudioPlayerEvent) {
        switch event {
        case .startedPlaying:
            playToAudio?.end()
            playToAudio = nil
        case .playedToEnd:
            guard state == .playing else { return }
            finish(because: .endOfBook)
        case .decodeFailed(let time):
            Task { await decodeFailed(at: time) }
        }
    }

    /// The xHE-AAC decoder bug (FB22340742) makes AVPlayer fail with -11821 at some positions. Like other clients,
    /// reload the timeline and carry on from a second earlier, up to ``maxDecodeRetries`` times; then pause and save.
    private func decodeFailed(at time: Double) async {
        guard let book, state == .playing || state == .paused else { return }
        let wasPlaying = state == .playing
        guard decodeRetries < Self.maxDecodeRetries else {
            log.error("A Book kept failing to decode; giving up")
            pause(because: .failed)
            loadGeneration += 1
            unload(problem: .cannotDecode)
            discardDamaged(book, reports: true)
            return
        }
        decodeRetries += 1
        log.notice("Decode failed at \(time, privacy: .public) s; reloading (try \(self.decodeRetries))")
        guard await reload(book, at: max(time - Self.decodeRetryBackoff, 0)) else { return }
        if wasPlaying, state == .playing { audio.play() }
    }

    /// Loads `book`'s timeline into the player again and moves to `time`, as a new load: returns `false` if a newer
    /// load or stop replaced it, or if the files couldn't be opened (then the Book is unloaded with `.cannotOpen`).
    func reload(_ book: BookDetail, at time: Double) async -> Bool {
        loadGeneration += 1
        let generation = loadGeneration
        do {
            try await audio.load(fileURLs(of: book))
        } catch {
            guard generation == loadGeneration else { return false }
            pause(because: .failed)
            unload(problem: .cannotOpen)
            discardDamaged(book, reports: true)
            return false
        }
        guard generation == loadGeneration else { return false }
        position = time
        pendingSeeks += 1
        await audio.seek(to: time)
        pendingSeeks -= 1
        return generation == loadGeneration
    }

    // MARK: - Saving

    /// Writes the position, now as the last-changed time, and Finished.
    func save() {
        guard let book else { return }
        let now = Date(millisecondsSince1970: clock.now.millisecondsSince1970)
        let progress = BookProgress(bookID: book.id, position: position, lastChanged: now, isFinished: isFinished)
        do {
            // The same write records it in the listening sessions (Player+Sessions.swift).
            try database.saveProgress(progress, listening: state == .playing)
        } catch {
            log.error("Couldn't save the position: \(String(describing: error), privacy: .public)")
        }
    }
}
