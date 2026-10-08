import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Synchronization
import Testing

extension SignedInFixture {
    /// The Library both here and on the Server.
    func haveBooks(_ ids: [String]) throws {
        server.books = ids.map { FakeServer.book($0, id: $0) }
        try haveLibrary(ids)
    }

    /// Listens to a Book for `seconds` (one write a second) from `position`, then pauses, moving the clock on.
    func listen(_ bookID: String, from position: Double, for seconds: Int, pause: Bool = true) async throws {
        for second in 0...seconds {
            try database.saveProgress(
                BookProgress(
                    bookID: bookID, position: position + Double(second), lastChanged: roundedNow, isFinished: false),
                listening: second < seconds || !pause)
            if second < seconds { await clock.advance(by: .seconds(1)) }
        }
    }

    var roundedNow: Date { Date(millisecondsSince1970: clock.now.millisecondsSince1970) }

    func outbox() -> SessionOutbox {
        SessionOutbox(database: database, api: server, auth: auth, clock: clock, progress: progressSync())
    }

    var sentBatches: [[OutboxSession]] {
        server.requests.compactMap { if case .syncSessions(_, let sessions, _, _) = $0 { sessions } else { nil } }
    }
}

@Suite("Listening sessions outbox")
struct SessionOutboxTests {
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The seven outbox rules

    @Test("Rule 1: sessions carry when the listener acted, not when they were sent")
    func userActedTimestamps() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let pressedPlay = fixture.roundedNow
        try await fixture.listen("a", from: 100, for: 30)
        let paused = fixture.roundedNow
        await fixture.clock.advance(by: .seconds(3 * 60 * 60))  // offline for three hours

        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        let sent = try #require(fixture.server.sessions.values.first)
        #expect(sent.startedAt == pressedPlay)
        #expect(sent.updatedAt == paused)
        #expect((sent.startTime, sent.currentTime, sent.timeListening) == (100, 130, 30))
        #expect(fixture.server.progress.first?.lastUpdate == paused.millisecondsSince1970)
    }

    @Test("Rule 2: an entry is deleted only when the Server confirms it, and progressSynced false counts")
    func deleteOnlyOnConfirmation() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        try fixture.database.endListeningSession(ofBook: "a")
        // Another device's newer progress: the Server keeps it and answers progressSynced: false.
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 900, isFinished: false, lastUpdate: fixture.ms(3600))
        ]
        fixture.server.isReachable = { _ in false }

        #expect(await fixture.outbox().send() == .unreachable)
        #expect(try fixture.database.listeningSessions().count == 1)

        fixture.server.isReachable = { _ in true }
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))
        #expect(try fixture.database.listeningSessions().isEmpty)
        #expect(fixture.server.progress.first?.position == 900)
    }

    @Test("Rule 3: resending is harmless: the Server keeps one session with the latest state")
    func harmlessResend() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 0, for: 10, pause: false)
        let outbox = fixture.outbox()
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))

        try await fixture.listen("a", from: 10, for: 20)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))

        #expect(fixture.server.sessions.count == 1)
        let sent = try #require(fixture.server.sessions.values.first)
        #expect((sent.currentTime, sent.timeListening) == (30, 30))
        #expect(fixture.sentBatches.map { $0.map(\.session.id) } == [[sent.id], [sent.id]])
    }

    @Test("Rule 4: local progress is never pruned because the Server lacks it")
    func neverPruned() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try fixture.database.saveProgress(
            BookProgress(bookID: "b-gone", position: 50, lastChanged: fixture.roundedNow, isFinished: false))
        try await fixture.listen("a", from: 100, for: 5)
        fixture.server.progress = []

        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        #expect(try fixture.database.progress(ofBook: "a")?.position == 105)
        #expect(try fixture.database.progress(ofBook: "b-gone")?.position == 50)
    }

    @Test("Rule 5: one failing Book doesn't block the others, and is skipped until the next catalogue sync")
    func oneFailingBook() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a", "b", "c"])
        try await fixture.listen("a", from: 0, for: 5)
        try await fixture.listen("b", from: 0, for: 5)
        try await fixture.listen("c", from: 0, for: 5)
        // The Server lost "b" since the last catalogue sync.
        fixture.server.books.removeAll { $0.id == "b" }
        let outbox = fixture.outbox()

        #expect(await outbox.send() == .sent(delivered: 2, rejected: 1))
        #expect(try fixture.database.listeningSessions().map(\.bookID) == ["b", "c"])  // c is still open

        try await fixture.listen("c", from: 5, for: 5)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(fixture.sentBatches.last?.map(\.session.bookID) == ["c"])

        // The next catalogue sync settles "b" (here: it's back), so it's tried again.
        fixture.server.books.append(FakeServer.book("b", id: "b"))
        await fixture.clock.advance(by: .seconds(1))
        try fixture.database.applyLibraryList(fixture.server.books, syncedAt: fixture.clock.now)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(try fixture.database.listeningSessions().map(\.bookID) == ["c"])
    }

    @Test("Rule 6: a fetch never overwrites a Book with unsent entries; after the send it's compared again")
    func fetchNeverOverwritesUnsent() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 900, isFinished: false, lastUpdate: fixture.ms(60))
        ]

        #expect(await fixture.progressSync().fetch() == .fetched(changedBookIDs: []))
        #expect(try fixture.database.progress(ofBook: "a")?.position == 105)

        // Sent and confirmed (the Server's progress is newer, so it keeps it): the fetch after the send takes it.
        try fixture.database.endListeningSession(ofBook: "a")
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))
        #expect(try fixture.database.progress(ofBook: "a")?.position == 900)
    }

    @Test(
        "Rule 7: after a send, progress from elsewhere only counts above about 2 s or a change in Finished",
        arguments: [(1.5, false, false), (2.5, false, true), (0, true, true)])
    func changeThreshold(moved: Double, finished: Bool, isChange: Bool) async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        try fixture.database.endListeningSession(ofBook: "a")
        let local = try #require(try fixture.database.progress(ofBook: "a"))
        // Another device acts a minute later, by `moved` seconds.
        let server = fixture.server
        let elsewhere = FetchedProgress(
            bookID: "a", position: 105 + moved, isFinished: finished, lastUpdate: fixture.ms(60))
        server.beforeHandling { request throws(ServerAPIError) in
            if case .progress = request { server.progress = [elsewhere] }
        }

        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        let after = try #require(try fixture.database.progress(ofBook: "a"))
        #expect((after != local) == isChange)
        if isChange { #expect(after.lastChanged == local.lastChanged.addingTimeInterval(60)) }
    }

    // MARK: Sending

    @Test("A send runs a progress fetch after the Server answers, and nothing is sent when nothing is unsent")
    func fetchAfterSend() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let outbox = fixture.outbox()
        #expect(await outbox.send() == .nothingToSend)
        #expect(fixture.sentBatches.isEmpty)
        #expect(fixture.progressRequests == 0)

        try await fixture.listen("a", from: 0, for: 5)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(fixture.progressRequests == 1)
        #expect(await outbox.send() == .nothingToSend)
        #expect(fixture.progressRequests == 1)
    }

    @Test("A failed send is quiet, confirms nothing, and the next trigger sends the same entries again")
    func retriesAtNextTrigger() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 0, for: 5)
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .syncSessions = request { throw .unexpectedStatus(500) }
        }
        let outbox = fixture.outbox()

        #expect(await outbox.send() == .failed)
        #expect(fixture.progressRequests == 0)

        fixture.server.beforeHandling(nil)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(fixture.sentBatches.count == 2)
    }

    @Test("A Not on Server Book's entries are held, not sent")
    func holdsNotOnServer() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a", "b"])
        try await fixture.listen("a", from: 0, for: 5)
        // Stage 1 flags "a" (it's downloaded) when the Server stops listing it.
        try fixture.database.queueDownload(ofBook: "a")
        _ = try fixture.database.startNextDownload()
        try fixture.database.setDownloadFiles([], ofBook: "a")
        try fixture.database.finishDownload(ofBook: "a", at: fixture.clock.now)
        try fixture.database.applyLibraryList([FakeServer.book("b", id: "b")], syncedAt: fixture.clock.now)

        #expect(await fixture.outbox().send() == .nothingToSend)
        #expect(fixture.sentBatches.isEmpty)
        #expect(try fixture.database.listeningSessions().count == 1)
    }

    @Test("Signed out, nothing is sent; after a rejected sign-in, nothing touches the network")
    func signedOutAndNeedsSignIn() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 0, for: 5)
        fixture.server.revokeAccessTokens()
        fixture.server.revokeRefreshTokens()
        let outbox = fixture.outbox()

        #expect(await outbox.send() == .needsSignIn)
        let requests = fixture.server.requests.count
        #expect(await outbox.send() == .needsSignIn)
        #expect(fixture.server.requests.count == requests)
        #expect(try fixture.database.listeningSessions().count == 1)
    }

    @Test("A session paused for 10 minutes is ended at the next send and leaves the outbox once confirmed")
    func endsLongPauseAtSend() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 0, for: 5)
        await fixture.clock.advance(by: .seconds(10 * 60))

        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        #expect(try fixture.database.listeningSessions().isEmpty)
    }

    @Test("While a Book plays, the outbox is sent every 60 s; while nothing plays, it isn't")
    func sendsEveryMinuteWhilePlaying() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let outbox = fixture.outbox()
        let loop = Task { await outbox.sendWhilePlaying() }
        defer { loop.cancel() }
        try await Task.sleep(for: .milliseconds(50))  // the loop reaches its first sleep

        try await fixture.listen("a", from: 0, for: 59, pause: false)
        #expect(fixture.sentBatches.isEmpty)
        try await fixture.listen("a", from: 59, for: 2, pause: false)
        await eventually { fixture.sentBatches.count == 1 }
        #expect(fixture.sentBatches.count == 1)
        try await fixture.listen("a", from: 61, for: 1)  // paused
        await fixture.clock.advance(by: .seconds(60))
        await fixture.clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.sentBatches.count == 1)
    }

    @Test("A send asked for while one runs makes it go round again, so the latest state goes out")
    func coalesces() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 0, for: 5, pause: false)
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let held = Mutex(false)
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            guard case .syncSessions = request, !held.withLock({ $0 }) else { return }
            held.withLock { $0 = true }
            enter.yield()
            for await _ in released { break }
        }
        let outbox = fixture.outbox()
        let first = Task { await outbox.send() }
        for await _ in entered { break }
        try await fixture.listen("a", from: 5, for: 5)
        let second = Task { await outbox.send() }
        await Task.yield()
        release.yield()

        _ = await first.value
        _ = await second.value
        #expect(fixture.sentBatches.map { $0.map(\.session.currentTime) } == [[5], [10]])
        #expect(try fixture.database.unsentListeningSessions().isEmpty)
    }
}
