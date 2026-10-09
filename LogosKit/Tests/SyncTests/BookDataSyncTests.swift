import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

extension SignedInFixture {
    /// The ids asked for in each `batch/get`, in order.
    var batches: [[String]] {
        server.requests.compactMap { if case .bookDataBatch(_, let ids, _) = $0 { ids } else { nil } }
    }

    /// The ids asked for one at a time (`items/:id?expanded=1`).
    var singleFetches: [String] {
        server.requests.compactMap { if case .bookData(_, let id, _) = $0 { id } else { nil } }
    }
}

/// `count` listed Books with ids `book-000`, `book-001`, …
func numberedBooks(_ count: Int) -> [ListedBook] {
    (0..<count).map { FakeServer.book("Book \($0)", id: String(format: "book-%03d", $0)) }
}

@Suite("Library sync, stage 2: full Book data")
struct BookDataSyncTests {
    let dawn = [
        Chapter(id: 0, start: 0, end: 40, title: "Dawn"), Chapter(id: 1, start: 40, end: 80, title: "Noon"),
    ]
    let saga = SeriesMembership(seriesID: "series-saga", name: "Fixture Saga", sequence: "1")
    let track = AudioTrack(
        index: 1, ino: "443", relPath: "01.mp3", size: 480_462, duration: 80, startOffset: 0, mimeType: "audio/mpeg")

    @Test("After the list, a sync fetches every Book's Chapters, tracks and Series")
    func fetchesFullData() async throws {
        let book = FakeServer.book("The First Light", id: "first-light")
        let fixture = try await SignedInFixture(books: [book, FakeServer.book("Plain Silence")])
        fixture.server.bookData = [BookData(book: book, chapters: dawn, tracks: [track], series: [saga])]

        #expect(await fixture.librarySync().sync(.launch) == .synced)

        let detail = try #require(try fixture.database.bookDetail(id: "first-light"))
        #expect(detail.chapters.chapters == dawn)
        #expect(detail.tracks == [track])
        #expect(detail.series == [saga])
        #expect(try fixture.database.booksBehindOnFullData().isEmpty)
    }

    @Test("Books are fetched in batches of 50")
    func batchesOf50() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(120))

        _ = await fixture.librarySync().sync(.launch)

        #expect(fixture.batches.map(\.count) == [50, 50, 20])
        #expect(Set(fixture.batches.joined()).count == 120)
    }

    @Test("A sync with nothing changed fetches no full data")
    func nothingBehind() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(3))
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        _ = await sync.sync(.manual)

        #expect(fixture.batches.count == 1)
    }

    @Test("Only Books whose updatedAt moved on are fetched again")
    func onlyChanged() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(3))
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        var books = numberedBooks(3)
        books[1] = FakeServer.book("Book 1", id: "book-001", updatedAt: 1_800_000_000_000)
        fixture.server.books = books
        _ = await sync.sync(.manual)

        #expect(fixture.batches.last == ["book-001"])
    }

    @Test("An interrupted sync resumes from whatever is still behind")
    func resumes() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(120))
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .bookDataBatch(_, let ids, _) = request, ids.contains("book-050") {
                throw .unreachable("offline")
            }
        }
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        #expect(try fixture.database.booksBehindOnFullData().count == 70)

        fixture.server.beforeHandling(nil)
        _ = await sync.sync(.manual)

        // First sync: 50 stored, then the second batch fails and the stage stops. Second sync: the other 70.
        #expect(fixture.batches.map(\.count) == [50, 50, 50, 20])
        #expect(Set(fixture.batches.dropFirst(2).joined()) == Set(numberedBooks(120).dropFirst(50).map(\.id)))
        #expect(try fixture.database.booksBehindOnFullData().isEmpty)
    }

    @Test("A batch the Server answers with an error doesn't stop the batches after it")
    func failedBatchSkipped() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(120))
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .bookDataBatch(_, let ids, _) = request, ids.contains("book-000") {
                throw .unexpectedStatus(403)
            }
        }

        #expect(await fixture.librarySync().sync(.launch) == .synced)

        #expect(fixture.batches.count == 3)
        #expect(try fixture.database.booksBehindOnFullData().count == 50)
    }

    @Test("A Book the Server leaves out of a batch stays behind; the rest are stored")
    func leftOut() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(2))
        let sync = fixture.librarySync()
        // book-001 is listed, then gone by the time the batch asks for it.
        let gate = AsyncGate()
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .bookDataBatch = request { await gate.wait() }
        }
        async let outcome = sync.sync(.launch)
        await fixture.clock.advance(by: .zero)
        fixture.server.books = [numberedBooks(2)[0]]
        await gate.open()
        _ = await outcome

        #expect(try fixture.database.booksBehindOnFullData() == ["book-001"])
    }

    @Test("When the sign-in is rejected during stage 2, the sync says so")
    func needsSignInDuringStage2() async throws {
        let fixture = try await SignedInFixture(books: numberedBooks(2))
        fixture.server.beforeHandling { [server = fixture.server] request throws(ServerAPIError) in
            if case .bookDataBatch = request {
                server.revokeAccessTokens()
                server.revokeRefreshTokens()
                throw .unauthorized
            }
        }

        #expect(await fixture.librarySync().sync(.launch) == .needsSignIn)
        #expect(try fixture.titles() == ["Book 0", "Book 1"])
    }

    @Test("A detail opened before its Book's data arrives fetches that Book right away, even while a sync runs")
    func detailFetchesRightAway() async throws {
        let book = FakeServer.book("The First Light", id: "first-light")
        let fixture = try await SignedInFixture(books: [book])
        fixture.server.bookData = [BookData(book: book, chapters: dawn, tracks: [track], series: [saga])]
        let gate = AsyncGate()
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .bookDataBatch = request { await gate.wait() }
        }
        let sync = fixture.librarySync()
        async let firstSync = sync.sync(.launch)
        await fixture.clock.advance(by: .zero)  // the sync is now held in stage 2
        #expect(fixture.batches.count == 1)

        await sync.fetchFullDataNow(ofBook: "first-light")

        #expect(fixture.singleFetches == ["first-light"])
        #expect(try fixture.database.bookDetail(id: "first-light")?.chapters.chapters == dawn)
        await gate.open()
        _ = await firstSync
    }

    @Test("A detail whose Book's data is current fetches nothing")
    func detailAlreadyCurrent() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One", id: "one")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)

        await sync.fetchFullDataNow(ofBook: "one")

        #expect(fixture.singleFetches.isEmpty)
    }

    @Test("A detail fetch that fails changes nothing and doesn't throw")
    func detailFetchFails() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("One", id: "one")])
        let sync = fixture.librarySync()
        _ = try fixture.database.applyLibraryList(fixture.server.books, syncedAt: fixture.clock.now)
        fixture.server.isReachable = { _ in false }

        await sync.fetchFullDataNow(ofBook: "one")

        #expect(fixture.singleFetches == ["one"])
        #expect(try fixture.database.booksBehindOnFullData() == ["one"])
    }
}
