import Domain
import Downloads
import Foundation
import Playback
import ServerAPI
import Store
import Sync
import Testing
import UI

/// A signed-in install with a Library, a downloaded Book, a cover, a player and an outbox, against a scripted Server.
@MainActor
struct SignedInApp {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let database: AppDatabase
    let files: DownloadFiles
    let covers: CoverFiles
    let auth: Auth
    let sync: LibrarySync
    let downloader: Downloader
    let audio = FakeAudioPlayer()
    let player: Player
    let identity = ServerIdentity(
        serverURL: URL(string: "https://abs.example.com")!, userID: "user-listener", username: "listener",
        libraryID: "library-books", libraryName: "Audiobooks")

    init() async throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
        covers = try CoverFiles(directory: directory.appending(path: "Covers"))
        try tokens.save(
            try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens)
        try database.saveServerIdentity(identity)
        auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
        sync = LibrarySync(database: database, api: server, auth: auth, clock: clock, covers: covers)
        downloader = Downloader(
            database: database, api: server, auth: auth, transfers: server.transfers, files: files, covers: covers,
            clock: clock)
        await downloader.start()
        player = Player(database: database, files: files, audio: audio, clock: clock)

        let books = ["first", "second"].map { id in
            BookData(
                book: FakeServer.book(id.capitalized, id: id), chapters: [],
                tracks: [
                    AudioTrack(
                        index: 1, ino: "ino-\(id)", relPath: "01.mp3", size: 1000, duration: 3600, startOffset: 0,
                        mimeType: "audio/mpeg")
                ], series: [])
        }
        server.books = books.map(\.book)
        server.bookData = books
        try database.applyLibraryList(books.map(\.book), syncedAt: clock.now)
        try database.applyBookData(books)
        for id in ["first", "second"] {
            server.transfers.serve(Data(count: 1000), bookID: id, ino: "ino-\(id)")
            try covers.save(Data([1, 2, 3]), forBook: id)
        }
        await downloader.download("first")
        await server.transfers.completeAll()
    }

    func signOutModel(onSignedOut: (() -> Void)? = nil) -> SignOutModel {
        SignOutModel(
            database: database, sync: sync, downloader: downloader, player: player, covers: covers,
            onSignedOut: onSignedOut)
    }

    var sentSessions: Int {
        server.requests.filter { if case .syncSessions = $0 { true } else { false } }.count
    }

    var logOuts: [String] {
        server.requests.compactMap { if case .logOut(_, let token) = $0 { token } else { nil } }
    }

    func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    }
}

@Suite("Sign out")
@MainActor
struct SignOutModelTests {
    @Test("Sign out first tries to send the outbox, then asks to confirm with what will be removed")
    func sendsThenConfirms() async throws {
        let app = try await SignedInApp()
        await app.player.play(bookID: "first")
        app.audio.advance(to: 40)
        let model = app.signOutModel()

        await model.start()

        #expect(app.sentSessions == 1)
        #expect(app.player.state == .paused)
        guard case .confirming(let summary) = model.step else {
            Issue.record("expected the confirmation, got \(model.step)")
            return
        }
        #expect(summary.downloadCount == 1)
        #expect(summary.downloadBytes == 1000)
        #expect(summary.unsentSessionCount == 0)
        #expect(try app.database.serverIdentity() != nil)
    }

    @Test("Sessions that couldn't be sent are counted in the confirmation")
    func unsentCounted() async throws {
        let app = try await SignedInApp()
        await app.player.play(bookID: "first")
        app.audio.advance(to: 40)
        app.server.isReachable = { _ in false }
        let model = app.signOutModel()

        await model.start()

        guard case .confirming(let summary) = model.step else {
            Issue.record("expected the confirmation, got \(model.step)")
            return
        }
        #expect(summary.unsentSessionCount == 1)
        #expect(SignOutModel.message(for: summary).contains("1 listening session"))
    }

    @Test("Cancelling the confirmation changes nothing")
    func cancel() async throws {
        let app = try await SignedInApp()
        let model = app.signOutModel()
        await model.start()

        model.cancel()

        #expect(model.step == .idle)
        #expect(try app.database.serverIdentity() != nil)
        #expect(try app.tokens.load() != nil)
        #expect(try !app.contents(of: app.files.directory).isEmpty)
    }

    @Test(
        "Confirming leaves the app like a fresh install: every table, file directory, token and per-identity object")
    func freshInstall() async throws {
        let app = try await SignedInApp()
        await app.player.play(bookID: "first")
        app.audio.advance(to: 40)
        app.player.setSpeed(2)
        try app.database.setSkipBack(.sixty)
        try app.database.setAllowsCellularDownloads(true)
        await app.downloader.download("second")  // in flight
        #expect(!app.server.transfers.pending.isEmpty)
        let refreshToken = try #require(try app.tokens.load()).refreshToken
        var signedOut = false
        let model = app.signOutModel { signedOut = true }

        await model.start()
        await model.confirm()

        // Playback: stopped, unloaded, settings back to the defaults.
        #expect(app.player.book == nil)
        #expect(app.player.state == .idle)
        #expect(app.player.speed == 1)
        #expect(app.player.skipBackInterval == .fifteen)
        // The Server revoked the refresh token; the Keychain item is gone.
        #expect(app.logOuts == [refreshToken])
        #expect(!app.server.accepts(refreshToken: refreshToken))
        #expect(try app.tokens.load() == nil)
        // Downloads: nothing in flight, nothing on disk; covers gone.
        #expect(app.server.transfers.pending.isEmpty)
        #expect(try app.contents(of: app.files.directory).isEmpty)
        #expect(try app.contents(of: app.covers.directory).isEmpty)
        // The database: every table empty (StoreTests checks the full list), so signed out.
        #expect(try app.database.serverIdentity() == nil)
        #expect(try app.database.libraryRows().isEmpty)
        #expect(try app.database.listeningSessions().isEmpty)
        #expect(try app.database.downloadPolicy() == .default)
        #expect(try app.database.playbackSettings() == .default)
        // The app drops its per-identity objects (Auth, Downloads).
        #expect(signedOut)
        #expect(model.step == .signedOut)
    }

    @Test("Signing out offline still wipes everything: the logout is best effort")
    func offline() async throws {
        let app = try await SignedInApp()
        app.server.isReachable = { _ in false }
        let model = app.signOutModel()

        await model.start()
        await model.confirm()

        #expect(try app.database.serverIdentity() == nil)
        #expect(try app.tokens.load() == nil)
    }

    @Test("The confirmation names the Downloads count and size, and any listening that would be lost")
    func message() {
        let none = SignOutSummary(
            downloadCount: 0, downloadBytes: 0, unsentSessionCount: 0, unsentFinishedChangeCount: 0)
        #expect(!SignOutModel.message(for: none).contains("Download"))
        #expect(!SignOutModel.message(for: none).contains("lost"))

        let some = SignOutSummary(
            downloadCount: 3, downloadBytes: 2_000_000_000, unsentSessionCount: 2, unsentFinishedChangeCount: 1)
        let text = SignOutModel.message(for: some)
        #expect(text.contains("3 Downloads (2 GB)"))
        #expect(text.contains("2 listening sessions"))
        #expect(text.contains("1 Finished change"))

        let one = SignOutSummary(
            downloadCount: 1, downloadBytes: 480_000_000, unsentSessionCount: 0, unsentFinishedChangeCount: 0)
        #expect(SignOutModel.message(for: one).contains("1 Download (480 MB)"))
    }

    @Test("After signing out, the launch model drops every per-identity model and shows sign-in")
    func launchModelDropsEverything() async throws {
        let app = try await SignedInApp()
        let launch = LaunchModel(
            database: app.database, makeLibrarySync: { _ in app.sync }, makeDownloader: { _ in app.downloader },
            player: app.player, signIn: SignIn(api: app.server, tokenStore: app.tokens, database: app.database),
            covers: app.covers)
        let observing = Task { await launch.observe() }
        defer { observing.cancel() }
        #expect(launch.library != nil)
        let model = try #require(launch.signOut)

        await model.start()
        await model.confirm()

        for _ in 0..<200 where launch.identity != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(launch.identity == nil)
        #expect(launch.library == nil)
        #expect(launch.inProgress == nil)
        #expect(launch.series == nil)
        #expect(launch.downloads == nil)
        #expect(launch.listening == nil)
        #expect(launch.settings == nil)
        #expect(launch.signInAgain == nil)
        #expect(launch.signOut == nil)
    }
}
