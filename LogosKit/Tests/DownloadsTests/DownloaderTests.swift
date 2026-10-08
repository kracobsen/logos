import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing

/// A signed-in Logos with a Library, against a scripted Server, with Downloads in a real temporary directory.
struct DownloadsFixture {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let files: DownloadFiles
    let covers: CoverFiles
    let storage = FakeStorageCapacity()

    init(books: [BookData]) async throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
        covers = try CoverFiles(directory: directory.appending(path: "Covers"))
        try tokens.save(
            try await server.logIn(to: server.address, username: "listener", password: "listenerpass").tokens)
        try database.saveServerIdentity(
            ServerIdentity(
                serverURL: server.address, userID: "user-listener", username: "listener", libraryID: "library-books",
                libraryName: "Audiobooks"))
        server.books = books.map(\.book)
        server.bookData = books
        try database.applyLibraryList(books.map(\.book), syncedAt: clock.now)
        for book in books {
            for track in book.tracks {
                server.transfers.serve(Self.bytes(of: track), bookID: book.book.id, ino: track.ino)
            }
        }
    }

    /// A new Downloads, as after a launch. Transfers enqueued before carry on, as the background session's do.
    func downloader(inForeground: Bool = true) async -> Downloader {
        let auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
        let downloader = Downloader(
            database: database, api: server, auth: auth, transfers: server.transfers, files: files, covers: covers,
            clock: clock, inForeground: inForeground, storage: storage)
        await downloader.start()
        return downloader
    }

    /// What the Server serves for a track: as many bytes as its `metadata.size`.
    static func bytes(of track: AudioTrack) -> Data {
        Data(repeating: UInt8(truncatingIfNeeded: track.relPath.count), count: Int(track.size))
    }

    func state(_ bookID: String) throws -> DownloadState? {
        try database.downloadStatus(ofBook: bookID)?.state
    }

    var pending: [FileTransfer] { server.transfers.pending.map(\.transfer) }

    func onDisk(_ bookID: String, _ relPath: String) -> Data? {
        try? Data(contentsOf: files.url(forBook: bookID, relPath: relPath))
    }

    var refreshCount: Int {
        server.requests.filter { if case .refresh = $0 { true } else { false } }.count
    }

    var fileRequests: [FakeServer.Request] {
        server.requests.filter { if case .file = $0 { true } else { false } }
    }
}

func book(_ id: String, files: [(String, Int64)], cover: Bool = false, ino: String? = nil) -> BookData {
    var listed = FakeServer.book(id.capitalized, id: id)
    listed = ListedBook(
        id: listed.id, mediaID: listed.mediaID, title: listed.title, subtitle: nil, authorName: listed.authorName,
        authorNameLF: listed.authorNameLF, narratorName: "", seriesName: "", description: nil, publishedYear: nil,
        genres: [], addedAt: listed.addedAt, updatedAt: listed.updatedAt, duration: 60 * Double(files.count),
        size: files.reduce(0) { $0 + $1.1 }, hasCover: cover)
    let tracks = files.enumerated().map { index, file in
        AudioTrack(
            index: index + 1, ino: ino ?? "ino-\(id)-\(file.0)", relPath: file.0, size: file.1, duration: 60,
            startOffset: 60 * Double(index), mimeType: "audio/mpeg")
    }
    return BookData(book: listed, chapters: [], tracks: tracks, series: [])
}

func transfer(_ bookID: String, _ relPath: String) -> FileTransfer {
    FileTransfer(bookID: bookID, relPath: relPath)
}

@Suite("Downloading a Book")
struct DownloaderTests {
    @Test("Every file and the cover are fetched; the Book is downloaded only when every file is verified")
    func downloadsWholeBook() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 300), ("CD 2/02.mp3", 200)], cover: true)
        ])
        fixture.server.covers = ["a": Data("cover".utf8)]
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(Set(fixture.pending) == [transfer("a", "01.mp3"), transfer("a", "CD 2/02.mp3")])
        #expect(try fixture.state("a") == .downloading)
        #expect(try fixture.database.downloadStatus(ofBook: "a")?.totalBytes == 500)
        #expect(try Data(contentsOf: fixture.covers.url(forBook: "a")) == Data("cover".utf8))

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloading)

        await fixture.server.transfers.complete(transfer("a", "CD 2/02.mp3"))
        #expect(try fixture.state("a") == .downloaded)
        #expect(fixture.onDisk("a", "01.mp3")?.count == 300)
        #expect(fixture.onDisk("a", "CD 2/02.mp3")?.count == 200)
    }

    @Test("Books download one at a time, first in, first out")
    func fifo() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
            book("c", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()

        await downloader.download("b")
        await downloader.download("a")
        await downloader.download("c")

        #expect(fixture.pending == [transfer("b", "01.mp3")])
        #expect(try fixture.state("a") == .queued)

        await fixture.server.transfers.complete(transfer("b", "01.mp3"))
        #expect(fixture.pending == [transfer("a", "01.mp3")])

        await fixture.server.transfers.completeAll()
        #expect(try [fixture.state("a"), fixture.state("b"), fixture.state("c")].allSatisfy { $0 == .downloaded })
    }

    @Test("Each transfer uses the ino from a fresh expanded Book, not the stored one")
    func freshIno() async throws {
        let stale = book("a", files: [("01.mp3", 10)])
        let fixture = try await DownloadsFixture(books: [stale])
        try fixture.database.applyBookData([stale])
        let moved = BookData(
            book: stale.book, chapters: [],
            tracks: [
                AudioTrack(
                    index: 1, ino: "ino-new", relPath: "01.mp3", size: 10, duration: 60, startOffset: 0,
                    mimeType: "audio/mpeg")
            ], series: [])
        fixture.server.bookData = [moved]
        fixture.server.transfers.serve(Data(count: 10), bookID: "a", ino: "ino-new")
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(fixture.server.transfers.pending.map(\.ino) == ["ino-new"])
        #expect(
            fixture.server.requests.contains(
                .bookData(
                    fixture.server.address, id: "a",
                    accessToken: try #require(
                        try fixture.tokens.load()?.accessToken))))
    }

    @Test("A transfer that stops part-way resumes from its partial data after a backoff, with the ino read again")
    func resumes() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        let bookDataRequests = fixture.server.requests.count { if case .bookData = $0 { true } else { false } }

        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 40)
        await fixture.clock.advance(by: Downloader.backoff[0])
        await fixture.eventually { fixture.pending.contains(transfer("a", "01.mp3")) }

        let resumed = try #require(fixture.server.transfers.pending.first)
        #expect(resumed.transfer == transfer("a", "01.mp3"))
        #expect(resumed.resumeData == FakeFileTransfers.resumeData(40))
        #expect(
            fixture.server.requests.count { if case .bookData = $0 { true } else { false } } == bookDataRequests + 1)

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("Before a Book is enqueued, a token with under 10 minutes left is refreshed, and the files carry the new one")
    func refreshesBeforeEnqueueing() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        await fixture.clock.advance(by: .seconds(3600 - 9 * 60))
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(fixture.refreshCount == 1)
        #expect(fixture.server.transfers.pending.first?.accessToken == (try fixture.tokens.load())?.accessToken)
    }

    @Test("With more than 10 minutes left, the token is used as it is")
    func noEarlyRefresh() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        await fixture.clock.advance(by: .seconds(3600 - 11 * 60))
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(fixture.refreshCount == 0)
    }

    @Test("A 401 refreshes once and re-enqueues only that file, from its partial data, without counting an attempt")
    func unauthorized() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10), ("02.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 4)
        await fixture.clock.advance(by: Downloader.backoff[0])
        await fixture.eventually { fixture.pending.contains(transfer("a", "01.mp3")) }
        let enqueuedBefore = fixture.server.transfers.enqueued.count

        // More 401s than a file has attempts.
        for round in 1...(Downloader.maxAttempts + 2) {
            fixture.server.revokeAccessTokens()
            await fixture.server.transfers.complete(transfer("a", "01.mp3"))
            #expect(fixture.refreshCount == round)
            #expect(try fixture.state("a") == .downloading)
        }

        let retries = fixture.server.transfers.enqueued.dropFirst(enqueuedBefore)
        #expect(retries.allSatisfy { $0.transfer == transfer("a", "01.mp3") })
        #expect(retries.allSatisfy { $0.resumeData == FakeFileTransfers.resumeData(4) })
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("A file of the wrong size is deleted and downloaded once more from scratch")
    func sizeMismatchOnce() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        fixture.server.transfers.serve(Data(count: 9), bookID: "a", ino: "ino-a-01.mp3")
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 4)
        await fixture.clock.advance(by: Downloader.backoff[0])
        await fixture.eventually { fixture.pending.contains(transfer("a", "01.mp3")) }
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(try fixture.state("a") == .downloading)
        let again = try #require(fixture.server.transfers.pending.first)
        #expect(again.transfer == transfer("a", "01.mp3"))
        #expect(again.resumeData == nil)

        fixture.server.transfers.serve(Data(count: 10), bookID: "a", ino: "ino-a-01.mp3")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("A second size mismatch fails the Book, and the queue moves on")
    func sizeMismatchTwice() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        fixture.server.transfers.serve(Data(count: 9), bookID: "a", ino: "ino-a-01.mp3")
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .failed)
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("On launch, transfers are rebuilt from the database: missing ones enqueued, running and verified ones not")
    func rebuildsOnLaunch() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10), ("02.mp3", 10), ("03.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let before = await fixture.downloader()
        await before.download("a")
        await before.download("b")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        // The app is killed; the system drops one transfer and keeps the other.
        await fixture.server.transfers.cancel(bookID: "a")
        await fixture.server.transfers.enqueue(
            FileTransferRequest(
                transfer: transfer("a", "03.mp3"), ino: "ino-a-03.mp3", server: fixture.server.address,
                accessToken: try #require(try fixture.tokens.load()?.accessToken),
                destination: fixture.files.url(forBook: "a", relPath: "03.mp3")))
        let enqueuedBefore = fixture.server.transfers.enqueued.count

        let after = await fixture.downloader()
        await after.resume()

        let rebuilt = fixture.server.transfers.enqueued.dropFirst(enqueuedBefore).map(\.transfer)
        #expect(rebuilt == [transfer("a", "02.mp3")])
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
        #expect(try fixture.state("b") == .downloaded)
    }

    @Test("A file that arrived just before a kill is verified on launch, without fetching it again")
    func verifiesArrivedFileOnLaunch() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let before = await fixture.downloader()
        await before.download("a")
        // The file was moved into place, but the app died before recording it.
        await fixture.server.transfers.cancel(bookID: "a")
        try FileManager.default.createDirectory(
            at: fixture.files.url(forBook: "a", relPath: "01.mp3").deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(count: 10).write(to: fixture.files.url(forBook: "a", relPath: "01.mp3"))
        let enqueuedBefore = fixture.server.transfers.enqueued.count

        await fixture.downloader().resume()

        #expect(fixture.server.transfers.enqueued.count == enqueuedBefore)
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("Cancelling deletes the Book's files and transfers, and the next Book starts")
    func cancel() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10), ("02.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        await downloader.cancel("a")

        #expect(try fixture.state("a") == nil)
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("A Book finished in the background doesn't start the next until Logos is in the foreground again")
    func nextBookFromForeground() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")
        await downloader.enteredBackground()

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .downloaded)
        #expect(fixture.pending.isEmpty)
        await downloader.resume()
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("Launched in the background for transfer events, Downloads finishes the Book but starts no other")
    func backgroundLaunch() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let before = await fixture.downloader()
        await before.download("a")
        await before.download("b")

        let relaunched = await fixture.downloader(inForeground: false)
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .downloaded)
        #expect(fixture.pending.isEmpty)
        await relaunched.resume()
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("Progress events show how far a file has got")
    func progress() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100), ("02.mp3", 100)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")

        await fixture.server.transfers.reportProgress(transfer("a", "01.mp3"), receivedBytes: 50)

        #expect(try fixture.database.downloadStatus(ofBook: "a")?.fractionDone == 0.25)
    }

    @Test("Offline when a Book starts: it waits, and the next foreground picks it up")
    func offline() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let downloader = await fixture.downloader()
        fixture.server.isReachable = { _ in false }

        await downloader.download("a")

        #expect(try fixture.state("a") == .downloading)
        #expect(fixture.pending.isEmpty)
        fixture.server.isReachable = { _ in true }
        await downloader.resume()
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
    }
}
