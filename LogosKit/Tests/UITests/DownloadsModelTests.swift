import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Downloads on screen")
@MainActor
struct DownloadsModelTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let server: FakeServer
    let database: AppDatabase
    let downloader: Downloader
    let sync: LibrarySync

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
        downloader = Downloader(
            database: database, api: server, auth: auth, transfers: server.transfers,
            files: try DownloadFiles(directory: directory.appending(path: "Downloads")), covers: nil, clock: clock)
        await downloader.start()

        let books = ["first", "second", "third"].map { id in
            let track = AudioTrack(
                index: 1, ino: "ino-\(id)", relPath: "01.mp3", size: 1000, duration: 60, startOffset: 0,
                mimeType: "audio/mpeg")
            return BookData(
                book: FakeServer.book(id.capitalized, id: id), chapters: [], tracks: [track],
                series: [SeriesMembership(seriesID: "saga", name: "Saga", sequence: String(id.count))])
        }
        server.books = books.map(\.book)
        server.bookData = books
        try database.applyLibraryList(books.map(\.book), syncedAt: clock.now)
        try database.applyBookData(books)
        for id in ["first", "second", "third"] {
            server.transfers.serve(Data(count: 1000), bookID: id, ino: "ino-\(id)")
        }
    }

    func model() -> DownloadsModel {
        DownloadsModel(database: database, downloader: downloader)
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Starting a Download shows it as active at once: in the queue, on the badge, with progress")
    func start() async throws {
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        await model.download("first")
        await model.download("second")
        await server.transfers.reportProgress(FileTransfer(bookID: "first", relPath: "01.mp3"), receivedBytes: 250)

        await eventually { model.list.queue.count == 2 && model.status(of: "first")?.receivedBytes == 250 }
        #expect(model.list.queue.map(\.id) == ["first", "second"])
        #expect(model.badgeCount == 2)
        #expect(model.action(forBook: "first", size: 1000) == .downloading(fraction: 0.25))
        #expect(model.action(forBook: "second", size: 1000) == .queued)
    }

    @Test("Book detail's primary action: Download with the size, then progress, then downloaded")
    func primaryAction() async throws {
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        guard case .download(let label) = model.action(forBook: "first", size: 480_000) else {
            Issue.record("expected Download")
            return
        }
        #expect(label.hasPrefix("Download · "))
        #expect(label.contains("480"))

        await model.download("first")
        await server.transfers.completeAll()

        await eventually { model.action(forBook: "first", size: 1000) == .downloaded }
        #expect(model.action(forBook: "first", size: 1000) == .downloaded)
        #expect(model.list.downloaded.map(\.id) == ["first"])
        #expect(model.badgeCount == 0)
        #expect(model.totalSize.contains("1"))
    }

    @Test("Cancel stops the Download and the Book is back to Download")
    func cancel() async throws {
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await model.download("first")

        await model.cancel("first")

        await eventually { model.list.queue.isEmpty }
        #expect(model.status(of: "first") == nil)
        #expect(server.transfers.pending.isEmpty)
    }

    @Test("A Download made elsewhere shows up at once in a new model")
    func readsAtOnce() async throws {
        await downloader.download("first")
        await server.transfers.completeAll()
        await downloader.download("second")

        let model = model()

        #expect(model.list.downloaded.map(\.id) == ["first"])
        #expect(model.list.queue.map(\.id) == ["second"])
        #expect(model.badgeCount == 1)
    }

    @Test("The Series \"Download Book N to continue\" button starts that Book's Download and opens it")
    func seriesContinue() async throws {
        let model = model()
        let page = SeriesPageModel(seriesID: "saga", name: "Saga", database: database, sync: sync)
        #expect(page.continueTarget?.action == .download)
        let target = try #require(page.continueTarget?.book.id)

        let opened = page.continueTapped(downloads: model)

        #expect(opened == target)
        await eventually { server.transfers.pending.count == 1 }
        #expect(server.transfers.pending.map(\.transfer.bookID) == [target])
    }
}
