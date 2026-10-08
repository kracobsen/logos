import Domain
import Foundation
import Playback
import ServerAPI
import Store
import Sync
import Synchronization
import Testing
import UI

/// Connectivity the test switches by hand.
@MainActor
final class FakeConnectivity: ConnectivityMonitor {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
    }

    func connectedUpdates() -> AsyncStream<Bool> { stream }

    func set(_ connected: Bool) { continuation.yield(connected) }
}

/// Records the background tasks begun and ended.
@MainActor
final class FakeBackgroundTasks: BackgroundTasks {
    private(set) var begun = 0
    private(set) var ended = 0

    func begin(_ name: String) -> () -> Void {
        begun += 1
        return { self.ended += 1 }
    }
}

@Suite("Sending listening")
@MainActor
struct ListeningReporterTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let server: FakeServer
    let database: AppDatabase
    let sync: LibrarySync
    let files: DownloadFiles
    let audio = FakeAudioPlayer()
    let connectivity = FakeConnectivity()
    let tasks = FakeBackgroundTasks()

    init() async throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let tokens = InMemoryTokenStore()
        try tokens.save(
            try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens)
        try database.saveServerIdentity(
            ServerIdentity(
                serverURL: server.address, userID: "user-listener", username: "listener", libraryID: "library-books",
                libraryName: "Audiobooks"))
        let auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
        sync = LibrarySync(database: database, api: server, auth: auth, clock: clock)
        files = try DownloadFiles(directory: directory.appending(path: "Downloads"))

        let track = AudioTrack(
            index: 1, ino: "ino-first", relPath: "01.mp3", size: 1000, duration: 3600, startOffset: 0,
            mimeType: "audio/mpeg")
        let book = BookData(
            book: FakeServer.book("First", id: "first"),
            chapters: [
                Chapter(id: 0, start: 0, end: 1800, title: "One"), Chapter(id: 1, start: 1800, end: 3600, title: "Two"),
            ],
            tracks: [track], series: [])
        server.books = [book.book]
        try database.applyLibraryList([book.book], syncedAt: clock.now)
        try database.applyBookData([book])
        let url = files.url(forBook: "first", relPath: "01.mp3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: url)
        try database.queueDownload(ofBook: "first")
        _ = try database.startNextDownload()
        try database.setDownloadFiles([track], ofBook: "first")
        for var file in try database.downloadFiles(ofBook: "first") {
            file.isVerified = true
            try database.saveDownloadFile(file)
        }
        try database.finishDownload(ofBook: "first", at: clock.now)
    }

    func player() -> Player {
        Player(database: database, files: files, audio: audio, clock: clock)
    }

    func reporter(_ player: Player?) -> ListeningReporter {
        ListeningReporter(outbox: sync.outbox, player: player, connectivity: connectivity, backgroundTasks: tasks)
    }

    var sends: Int {
        server.requests.filter { if case .syncSessions = $0 { true } else { false } }.count
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Plays "first" for a few seconds, leaving a session to send.
    func listen(_ player: Player) async {
        await player.play(bookID: "first")
        for _ in 0..<12 {
            audio.advance(by: 0.25)
            await clock.advance(by: .milliseconds(250))
        }
    }

    @Test("Pausing sends straight away, in a background task, and plays on without waiting for it")
    func sendsOnPause() async throws {
        let player = player()
        let reporter = reporter(player)
        await listen(player)
        let running = Task { await reporter.run() }
        defer { running.cancel() }
        await eventually { sends == 1 }  // the launch send

        player.pause()
        await eventually { sends == 2 }

        #expect(sends == 2)
        #expect(tasks.begun == 1)
        await eventually { tasks.ended == 1 }
        #expect(tasks.ended == 1)
        #expect(server.sessions.values.first?.currentTime == 3)
    }

    @Test("A Sleep Timer stop sends the ended session straight away")
    func sendsOnSleepTimer() async throws {
        let player = player()
        let reporter = reporter(player)
        let running = Task { await reporter.run() }
        defer { running.cancel() }
        await listen(player)
        player.setSleepTimer(chapters: 1)

        audio.advance(to: 1800.1)
        await eventually { server.sessions.values.first?.currentTime == 1800 }

        #expect(server.sessions.values.first?.currentTime == 1800)
        await eventually { (try? database.listeningSessions().isEmpty) == true }
        #expect(try database.listeningSessions().isEmpty)
    }

    @Test("Going to the background sends in a background task; returning to the foreground sends")
    func sendsOnBackgroundAndForeground() async throws {
        let player = player()
        let reporter = reporter(player)
        await listen(player)

        reporter.enteredBackground()
        await eventually { sends == 1 }
        #expect(tasks.begun == 1)

        await listen(player)
        reporter.enteredForeground()
        await eventually { sends == 2 }
        #expect(sends == 2)
    }

    @Test("Listening done offline is sent when the network comes back")
    func sendsWhenNetworkReturns() async throws {
        let player = player()
        let reporter = reporter(player)
        server.isReachable = { _ in false }
        let running = Task { await reporter.run() }
        defer { running.cancel() }
        connectivity.set(false)
        await listen(player)
        player.pause()
        await eventually { tasks.ended == 1 }  // the pause's send failed
        #expect(server.sessions.isEmpty)

        server.isReachable = { _ in true }
        connectivity.set(true)
        await eventually { !server.sessions.isEmpty }

        #expect(server.sessions.values.first?.currentTime == 3)
    }
}
