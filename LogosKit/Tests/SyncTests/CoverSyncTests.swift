import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

/// A Book the Server lists with a cover, serving `cover-<id>` as its data.
func coveredBook(_ title: String, id: String, updatedAt: Int64 = 1_700_000_000_000) -> ListedBook {
    let book = FakeServer.book(title, id: id, updatedAt: updatedAt)
    return ListedBook(
        id: book.id, mediaID: book.mediaID, title: book.title, subtitle: book.subtitle, authorName: book.authorName,
        authorNameLF: book.authorNameLF, narratorName: book.narratorName, seriesName: book.seriesName,
        description: book.description, publishedYear: book.publishedYear, genres: book.genres, addedAt: book.addedAt,
        updatedAt: book.updatedAt, duration: book.duration, size: book.size, hasCover: true)
}

extension SignedInFixture {
    /// The fixture's covers directory, in its temporary directory.
    func coverFiles() throws -> CoverFiles {
        try CoverFiles(directory: directory.appending(path: "Covers"))
    }

    func librarySync(covers: CoverFiles) -> LibrarySync {
        LibrarySync(database: database, api: server, auth: auth, clock: clock, covers: covers)
    }

    /// Lists `books` and serves a cover for each one that has one.
    func serve(_ books: [ListedBook], coverSuffix: String = "") {
        server.books = books
        server.covers = Dictionary(
            uniqueKeysWithValues: books.filter(\.hasCover).map { ($0.id, Data("cover-\($0.id)\(coverSuffix)".utf8)) })
    }

    var coverRequests: [String] {
        server.requests.compactMap { if case .cover(_, let bookID, _) = $0 { bookID } else { nil } }
    }
}

@Suite("Library sync, stage 3: covers")
struct CoverSyncTests {
    @Test("A sync fetches every listed cover into the covers directory")
    func fetchesCovers() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1"), coveredBook("Two", id: "2"), FakeServer.book("Bare", id: "3")])
        let covers = try fixture.coverFiles()

        #expect(await fixture.librarySync(covers: covers).sync(.launch) == .synced)

        #expect(try Data(contentsOf: covers.url(forBook: "1")) == Data("cover-1".utf8))
        #expect(try Data(contentsOf: covers.url(forBook: "2")) == Data("cover-2".utf8))
        #expect(!covers.exists(forBook: "3"))
        #expect(Set(fixture.coverRequests) == ["1", "2"])
    }

    @Test("Covers that are up to date aren't fetched again")
    func upToDateNotFetched() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1"), FakeServer.book("Bare", id: "3")])
        let sync = fixture.librarySync(covers: try fixture.coverFiles())
        _ = await sync.sync(.launch)
        let requests = fixture.coverRequests.count

        #expect(await sync.sync(.manual) == .synced)

        #expect(fixture.coverRequests.count == requests)
    }

    @Test("A Book whose updatedAt changes has its cover fetched again")
    func refetchesWhenUpdated() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1"), coveredBook("Two", id: "2")])
        let covers = try fixture.coverFiles()
        let sync = fixture.librarySync(covers: covers)
        _ = await sync.sync(.launch)

        fixture.serve(
            [coveredBook("One", id: "1", updatedAt: 1_800_000_000_000), coveredBook("Two", id: "2")],
            coverSuffix: "-new")
        _ = await sync.sync(.manual)

        #expect(fixture.coverRequests.filter { $0 == "1" }.count == 2)
        #expect(fixture.coverRequests.filter { $0 == "2" }.count == 1)
        #expect(try Data(contentsOf: covers.url(forBook: "1")) == Data("cover-1-new".utf8))
    }

    @Test("A Book whose cover the Server removed loses its cover file")
    func coverRemoved() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1")])
        let covers = try fixture.coverFiles()
        let sync = fixture.librarySync(covers: covers)
        _ = await sync.sync(.launch)

        fixture.serve([FakeServer.book("One", id: "1", updatedAt: 1_800_000_000_000)])
        _ = await sync.sync(.manual)

        #expect(!covers.exists(forBook: "1"))
    }

    @Test("A Book the Server no longer lists is deleted along with its cover")
    func removedBookLosesCover() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("Stays", id: "1"), coveredBook("Goes", id: "2")])
        let covers = try fixture.coverFiles()
        let sync = fixture.librarySync(covers: covers)
        _ = await sync.sync(.launch)

        fixture.serve([coveredBook("Stays", id: "1")])
        _ = await sync.sync(.manual)

        #expect(covers.exists(forBook: "1"))
        #expect(!covers.exists(forBook: "2"))
    }

    @Test(
        "A cover that fails to download stays behind and is tried at the next sync; the others still arrive",
        arguments: [ServerAPIError.unreachable("offline"), .unexpectedStatus(500), .rateLimited]
    )
    func failedCoverRetried(error: ServerAPIError) async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1"), coveredBook("Two", id: "2")])
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .cover(_, "1", _) = request { throw error }
        }
        let covers = try fixture.coverFiles()
        let sync = fixture.librarySync(covers: covers)

        #expect(await sync.sync(.launch) == .synced)
        #expect(!covers.exists(forBook: "1"))
        #expect(covers.exists(forBook: "2"))

        fixture.server.beforeHandling(nil)
        _ = await sync.sync(.manual)
        #expect(covers.exists(forBook: "1"))
        #expect(fixture.coverRequests.filter { $0 == "2" }.count == 1)
    }

    @Test("A listed cover the Server can't find (404) isn't asked for again until the Book changes")
    func notFoundNotRetried() async throws {
        let fixture = try await SignedInFixture()
        fixture.server.books = [coveredBook("One", id: "1")]
        let sync = fixture.librarySync(covers: try fixture.coverFiles())
        _ = await sync.sync(.launch)
        _ = await sync.sync(.manual)

        #expect(fixture.coverRequests == ["1"])
    }

    @Test("Covers are fetched a few at a time, in parallel")
    func aFewAtATime() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve((1...10).map { coveredBook("Book \($0)", id: "\($0)") })
        let gate = AsyncGate()
        let inFlight = Counter()
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            guard case .cover = request else { return }
            await inFlight.add(1)
            await gate.wait()
            await inFlight.add(-1)
        }
        let covers = try fixture.coverFiles()
        let sync = fixture.librarySync(covers: covers)

        async let outcome = sync.sync(.launch)
        await fixture.clock.advance(by: .zero)  // lets the first covers reach the Server
        #expect(await inFlight.peak == LibrarySync.coverConcurrency)
        await gate.open()

        #expect(await outcome == .synced)
        #expect(try covers.bookIDs().count == 10)
        #expect(await inFlight.peak == LibrarySync.coverConcurrency)
    }

    @Test("When the list fails, no covers are fetched")
    func listFails() async throws {
        let fixture = try await SignedInFixture()
        fixture.serve([coveredBook("One", id: "1")])
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .books = request { throw .unexpectedStatus(500) }
        }
        #expect(await fixture.librarySync(covers: try fixture.coverFiles()).sync(.launch) == .failed)
        #expect(fixture.coverRequests.isEmpty)
    }
}

/// Counts something going up and down, remembering the highest value.
actor Counter {
    private(set) var value = 0
    private(set) var peak = 0

    func add(_ delta: Int) {
        value += delta
        peak = max(peak, value)
    }
}
