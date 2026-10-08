import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

extension SignedInFixture {
    /// The fixture's clock time plus `seconds`, in the Server's ms.
    func ms(_ seconds: TimeInterval = 0) -> Int64 {
        clock.now.addingTimeInterval(seconds).millisecondsSince1970
    }

    func progressSync() -> ProgressSync {
        ProgressSync(database: database, api: server, auth: auth)
    }

    var progressRequests: Int {
        server.requests.filter { if case .progress = $0 { true } else { false } }.count
    }

    /// Puts the Books in the Store, as a finished stage 1 would.
    func haveLibrary(_ ids: [String]) throws {
        try database.applyLibraryList(ids.map { FakeServer.book($0, id: $0) }, syncedAt: clock.now)
    }
}

@Suite("Progress fetch")
struct ProgressSyncTests {
    @Test("Newer progress from the Server replaces the local position and Finished, with the Server's time")
    func serverNewerWins() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a", "b"])
        try fixture.database.saveProgress(
            BookProgress(bookID: "a", position: 100, lastChanged: fixture.clock.now, isFinished: false))
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 900, isFinished: false, lastUpdate: fixture.ms(60)),
            FetchedProgress(bookID: "b", position: 3600, isFinished: true, lastUpdate: fixture.ms(60)),
        ]

        let outcome = await fixture.progressSync().fetch()

        #expect(outcome == .fetched(changedBookIDs: ["a", "b"]))
        #expect(
            try fixture.database.progress(ofBook: "a")
                == BookProgress(
                    bookID: "a", position: 900, lastChanged: fixture.clock.now.addingTimeInterval(60),
                    isFinished: false))
        #expect(try fixture.database.progress(ofBook: "b")?.isFinished == true)
    }

    @Test("Local progress changed more recently than the Server's is kept", arguments: [-60.0, 0])
    func localNewerWins(serverSecondsLater: TimeInterval) async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        let local = BookProgress(bookID: "a", position: 100, lastChanged: fixture.clock.now, isFinished: false)
        try fixture.database.saveProgress(local)
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 3600, isFinished: true, lastUpdate: fixture.ms(serverSecondsLater))
        ]

        #expect(await fixture.progressSync().fetch() == .fetched(changedBookIDs: []))

        #expect(try fixture.database.progress(ofBook: "a") == local)
    }

    @Test(
        "Newer progress only counts as a change if the position moved by more than about 2 s",
        arguments: [(1.5, false), (-2.0, false), (2.5, true), (-2.5, true)]
    )
    func twoSecondThreshold(moved: TimeInterval, isChange: Bool) async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        let local = BookProgress(bookID: "a", position: 100, lastChanged: fixture.clock.now, isFinished: false)
        try fixture.database.saveProgress(local)
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 100 + moved, isFinished: false, lastUpdate: fixture.ms(60))
        ]

        let outcome = await fixture.progressSync().fetch()

        #expect(outcome == .fetched(changedBookIDs: isChange ? ["a"] : []))
        #expect(try fixture.database.progress(ofBook: "a")?.position == (isChange ? 100 + moved : 100))
    }

    @Test("Newer progress that only changes Finished is a change, and brings the Server's position")
    func finishedAloneIsAChange() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        try fixture.database.saveProgress(
            BookProgress(bookID: "a", position: 3599, lastChanged: fixture.clock.now, isFinished: false))
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 3600, isFinished: true, lastUpdate: fixture.ms(60))
        ]

        #expect(await fixture.progressSync().fetch() == .fetched(changedBookIDs: ["a"]))
        #expect(try fixture.database.progress(ofBook: "a")?.isFinished == true)
        #expect(try fixture.database.progress(ofBook: "a")?.position == 3600)
    }

    @Test("Progress for Books the Library doesn't have is ignored")
    func unknownBooksIgnored() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        fixture.server.progress = [
            FetchedProgress(bookID: "elsewhere", position: 50, isFinished: false, lastUpdate: fixture.ms())
        ]

        #expect(await fixture.progressSync().fetch() == .fetched(changedBookIDs: []))
        #expect(try fixture.database.progress(ofBook: "elsewhere") == nil)
    }

    @Test("Local progress the Server doesn't have is never deleted")
    func localNeverPruned() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        let local = BookProgress(bookID: "a", position: 100, lastChanged: fixture.clock.now, isFinished: false)
        try fixture.database.saveProgress(local)
        fixture.server.progress = []

        #expect(await fixture.progressSync().fetch() == .fetched(changedBookIDs: []))
        #expect(try fixture.database.progress(ofBook: "a") == local)
    }

    @Test("Failures are quiet and change nothing")
    func failures() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(["a"])
        fixture.server.progress = [FetchedProgress(bookID: "a", position: 50, isFinished: false, lastUpdate: 1)]
        let sync = fixture.progressSync()

        fixture.server.isReachable = { _ in false }
        #expect(await sync.fetch() == .unreachable)
        fixture.server.isReachable = { _ in true }
        fixture.server.beforeHandling { _ throws(ServerAPIError) in throw .unexpectedStatus(500) }
        #expect(await sync.fetch() == .failed)
        fixture.server.beforeHandling(nil)
        fixture.server.revokeAccessTokens()
        fixture.server.revokeRefreshTokens()
        #expect(await sync.fetch() == .needsSignIn)

        #expect(try fixture.database.progress(ofBook: "a") == nil)
    }

    @Test("Fetches that arrive while one runs share it")
    func concurrentFetchesShare() async throws {
        let fixture = try await SignedInFixture()
        let gate = AsyncGate()
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .progress = request { await gate.wait() }
        }
        let sync = fixture.progressSync()

        async let first = sync.fetch()
        async let second = sync.fetch()
        await fixture.clock.advance(by: .zero)
        await gate.open()

        #expect(await [first, second] == [.fetched(changedBookIDs: []), .fetched(changedBookIDs: [])])
        #expect(fixture.progressRequests == 1)
    }

    @Test("Progress for 3000 Books is applied in one go")
    func large() async throws {
        let ids = (0..<3000).map { "book-\($0)" }
        let fixture = try await SignedInFixture()
        try fixture.haveLibrary(ids)
        fixture.server.progress = ids.enumerated().map { index, id in
            FetchedProgress(bookID: id, position: Double(index + 10), isFinished: false, lastUpdate: fixture.ms())
        }

        let started = ContinuousClock.now
        let outcome = await fixture.progressSync().fetch()
        print("Fetching and applying progress for 3000 Books took \(ContinuousClock.now - started)")

        #expect(outcome == .fetched(changedBookIDs: Set(ids)))
        #expect(try fixture.database.inProgressRows().count == 3000)
    }
}

@Suite("Progress fetch triggers")
struct ProgressTriggerTests {
    @Test("Launch and Refresh fetch progress after the Library list, so new Books get theirs")
    func launchAndRefresh() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("New", id: "new")])
        fixture.server.progress = [
            FetchedProgress(bookID: "new", position: 50, isFinished: false, lastUpdate: fixture.ms())
        ]
        let sync = fixture.librarySync()

        #expect(await sync.sync(.launch) == .synced)
        #expect(try fixture.database.progress(ofBook: "new")?.position == 50)

        _ = await sync.sync(.manual)
        #expect(fixture.progressRequests == 2)
    }

    @Test("Every return to the foreground fetches progress, even soon after a sync")
    func everyForeground() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("A", id: "a")])
        let sync = fixture.librarySync()
        _ = await sync.sync(.launch)
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 50, isFinished: false, lastUpdate: fixture.ms(60))
        ]
        await fixture.clock.advance(by: .seconds(60))

        #expect(await sync.sync(.foreground) == .notNeeded)

        #expect(fixture.listRequests == 1)
        #expect(fixture.progressRequests == 2)
        #expect(try fixture.database.progress(ofBook: "a")?.position == 50)
    }

    @Test("A Server below 2.36 gets no progress fetch either")
    func notWhenTooOld() async throws {
        let fixture = try await SignedInFixture(books: [FakeServer.book("A", id: "a")])
        fixture.server.version = "2.35.0"

        _ = await fixture.librarySync().sync(.launch)

        #expect(fixture.progressRequests == 0)
    }
}
