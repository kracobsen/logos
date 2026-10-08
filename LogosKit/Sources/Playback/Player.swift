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
    }

    public private(set) var state: State = .idle
    /// The loaded Book, from the moment it starts loading.
    public private(set) var book: BookDetail?
    /// In Book seconds. Moves to a seek's target straight away.
    public private(set) var position: Double = 0
    /// Whether the loaded Book is Finished.
    public private(set) var isFinished = false
    /// The speed playing runs at.
    public private(set) var rate: Float
    public private(set) var problem: Problem?

    /// How often the position is published while playing, in seconds.
    public static let publishInterval = 0.25
    /// How often the position is saved while playing.
    public static let saveInterval = Duration.seconds(1)
    /// How many times a decode failure is worked around by reloading before giving up (FB22340742).
    public static let maxDecodeRetries = 10
    /// How far before a decode failure playing restarts after reloading, in seconds.
    public static let decodeRetryBackoff = 1.0

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let files: DownloadFiles
    @ObservationIgnored private let audio: any AudioPlayer
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var timeObservation: AudioPlayerObservation?
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Bumped by every load, so an older load that finishes late is ignored.
    @ObservationIgnored private var loadGeneration = 0
    /// Seeks sent to the player and not finished yet; time reports are stale until they are.
    @ObservationIgnored private var pendingSeeks = 0
    @ObservationIgnored private var decodeRetries = 0
    @ObservationIgnored private var playToAudio: SignpostInterval?

    public init(database: AppDatabase, files: DownloadFiles, audio: any AudioPlayer, clock: any Clock) {
        self.database = database
        self.files = files
        self.audio = audio
        self.clock = clock
        rate = audio.rate
        timeObservation = audio.observeTime(every: Self.publishInterval) { [weak self] time in
            self?.timePassed(time)
        }
        audio.onEvent = { [weak self] event in self?.handle(event) }
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
            _ = await load(bookID)
        } catch {
            log.error("Couldn't read the last-played Book: \(String(describing: error), privacy: .public)")
        }
    }

    /// Loads the Book paused at its saved position. Returns whether it's loaded (and no later load replaced it).
    private func load(_ bookID: String) async -> Bool {
        pause()
        loadGeneration += 1
        let generation = loadGeneration
        problem = nil
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
        pause()
        loadGeneration += 1
        unload(problem: nil)
    }

    private func unload(problem: Problem?) {
        saving?.cancel()
        saving = nil
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

    /// Pauses and saves. Does nothing unless playing.
    public func pause() {
        guard state == .playing else { return }
        audio.pause()
        state = .paused
        saving?.cancel()
        saving = nil
        if pendingSeeks == 0 { position = audio.currentTime }
        save()
    }

    public func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    /// Moves to `time` (in Book seconds): the position moves at once, the audio follows. Saves.
    public func seek(to time: Double) {
        guard let book, state != .idle else { return }
        let target = min(max(time, 0), book.duration)
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

    /// Skips `seconds` forward (or back, if negative), staying within the Book.
    public func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    /// Jumps to the start of the Chapter at `index`.
    public func jump(toChapter index: Int) {
        guard let chapters = book?.chapters.chapters, chapters.indices.contains(index) else { return }
        seek(to: chapters[index].start)
    }

    /// Sets the speed playing runs at.
    public func setRate(_ rate: Float) {
        audio.rate = rate
        self.rate = rate
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
            guard let book, state == .playing else { return }
            state = .paused
            saving?.cancel()
            saving = nil
            position = book.duration
            save()
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
            pause()
            problem = .cannotDecode
            return
        }
        decodeRetries += 1
        log.notice("Decode failed at \(time, privacy: .public) s; reloading (try \(self.decodeRetries))")
        loadGeneration += 1
        let generation = loadGeneration
        let resumeAt = max(time - Self.decodeRetryBackoff, 0)
        do {
            try await audio.load(fileURLs(of: book))
        } catch {
            guard generation == loadGeneration else { return }
            pause()
            unload(problem: .cannotOpen)
            return
        }
        guard generation == loadGeneration else { return }
        position = resumeAt
        pendingSeeks += 1
        await audio.seek(to: resumeAt)
        pendingSeeks -= 1
        guard generation == loadGeneration else { return }
        if wasPlaying, state == .playing { audio.play() }
    }

    // MARK: - Saving

    /// Writes the position, now as the last-changed time, and Finished.
    private func save() {
        guard let book else { return }
        let now = Date(millisecondsSince1970: clock.now.millisecondsSince1970)
        let progress = BookProgress(bookID: book.id, position: position, lastChanged: now, isFinished: isFinished)
        do {
            try database.saveProgress(progress)
        } catch {
            log.error("Couldn't save the position: \(String(describing: error), privacy: .public)")
        }
    }
}
