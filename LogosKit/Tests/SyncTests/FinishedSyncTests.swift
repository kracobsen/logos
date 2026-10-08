import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

extension SignedInFixture {
    /// The Player finishing the Book now (paused within the last 30 s, or at the end): position at the end.
    func finish(_ bookID: String) throws {
        try database.saveProgress(
            BookProgress(bookID: bookID, position: 3600, lastChanged: roundedNow, isFinished: true), listening: false)
    }

    var finishedPatches: [FinishedChange] {
        server.requests.compactMap { if case .updateFinished(_, let change, _, _) = $0 { change } else { nil } }
    }

    /// The kinds of request the Server got that matter for the outbox, in order.
    var outboxRequests: [String] {
        server.requests.compactMap { request in
            switch request {
            case .progress: "fetch"
            case .syncSessions: "sessions"
            case .updateFinished: "finished"
            default: nil
            }
        }
    }

    func serverProgress(_ bookID: String) -> FetchedProgress? {
        server.progress.first { $0.bookID == bookID }
    }
}

@Suite("Finished sync")
struct FinishedSyncTests {
    @Test("Finished by hand reaches the Server as a PATCH with when the listener acted")
    func finishedByHand() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        let acted = fixture.roundedNow
        try fixture.database.setFinished(true, ofBook: "a", at: acted)
        await fixture.clock.advance(by: .seconds(3 * 60 * 60))  // offline for three hours

        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        #expect(
            fixture.finishedPatches == [
                FinishedChange(bookID: "a", isFinished: true, position: 3600, lastUpdate: acted)
            ])
        #expect(fixture.serverProgress("a")?.isFinished == true)
        #expect(try fixture.database.pendingFinishedChanges().isEmpty)
        #expect(try fixture.database.progress(ofBook: "a")?.isFinished == true)
    }

    @Test("Cleared Finished reaches the Server, which puts the Book at 0")
    func clearedByHand() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))
        await fixture.clock.advance(by: .seconds(60))

        try fixture.database.setFinished(false, ofBook: "a", at: fixture.roundedNow)
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))

        #expect(fixture.finishedPatches.map(\.isFinished) == [true, false])
        #expect(fixture.serverProgress("a")?.isFinished == false)
        #expect(fixture.serverProgress("a")?.position == 0)
    }

    @Test("The guard fetch comes first, and the PATCH only after the Book's sessions are acknowledged")
    func afterSessions() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)

        #expect(await fixture.outbox().send() == .sent(delivered: 2, rejected: 0))

        // Guard fetch, sessions, a fetch to see what the sessions did, the PATCH, the usual fetch after a send.
        #expect(fixture.outboxRequests == ["fetch", "sessions", "fetch", "finished", "fetch"])
        #expect(fixture.serverProgress("a")?.isFinished == true)
    }

    @Test("Sessions that fail to send hold the Book's Finished change back")
    func heldBySessions() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        fixture.server.beforeHandling { request throws(ServerAPIError) in
            if case .syncSessions = request { throw .unexpectedStatus(500) }
        }

        #expect(await fixture.outbox().send() == .failed)

        #expect(fixture.finishedPatches.isEmpty)
        #expect(try fixture.database.pendingFinishedChanges().count == 1)

        fixture.server.beforeHandling(nil)
        #expect(await fixture.outbox().send() == .sent(delivered: 2, rejected: 0))
        #expect(fixture.serverProgress("a")?.isFinished == true)
    }

    @Test("A newer change on the Server drops the Finished change, and the Server's state is applied")
    func serverNewerWins() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        // Another device listened a minute after the listener marked it Finished here.
        fixture.server.progress = [
            FetchedProgress(bookID: "a", position: 900, isFinished: false, lastUpdate: fixture.ms(60))
        ]

        #expect(await fixture.outbox().send() == .sent(delivered: 0, rejected: 0))

        #expect(fixture.finishedPatches.isEmpty)
        #expect(try fixture.database.pendingFinishedChanges().isEmpty)
        let local = try #require(try fixture.database.progress(ofBook: "a"))
        #expect((local.position, local.isFinished) == (900, false))
    }

    @Test("An older Server state doesn't stop the change, even after this device's sessions stamp the Server's time")
    func ownSessionsDontOverrule() async throws {
        let fixture = try await SignedInFixture()
        fixture.server.stampsFirstProgressWithServerTime = true
        try fixture.haveBooks(["a"])
        // Offline: listen to a Book the Server has no progress for, then mark it Finished.
        try await fixture.listen("a", from: 100, for: 5)
        let acted = fixture.roundedNow
        try fixture.database.setFinished(true, ofBook: "a", at: acted)
        await fixture.clock.advance(by: .seconds(3 * 60 * 60))

        #expect(await fixture.outbox().send() == .sent(delivered: 2, rejected: 0))

        let server = try #require(fixture.serverProgress("a"))
        #expect(server.isFinished)
        #expect(server.lastUpdate == acted.millisecondsSince1970)
        #expect(try fixture.database.progress(ofBook: "a")?.isFinished == true)
    }

    @Test("Listening to the end finishes the Book on the Server through its session: no PATCH needed")
    func finishedBySession() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        fixture.server.progress = [FetchedProgress(bookID: "a", position: 3000, isFinished: false, lastUpdate: 1)]
        try await fixture.listen("a", from: 3590, for: 5, pause: false)
        try fixture.finish("a")

        #expect(await fixture.outbox().send() == .sent(delivered: 2, rejected: 0))

        #expect(fixture.finishedPatches.isEmpty)
        #expect(fixture.serverProgress("a")?.isFinished == true)
        #expect(try fixture.database.pendingFinishedChanges().isEmpty)
    }

    @Test("A Not on Server Book's change is held, and sent if the same id comes back")
    func holdsNotOnServer() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try fixture.database.queueDownload(ofBook: "a")
        _ = try fixture.database.startNextDownload()
        try fixture.database.setDownloadFiles([], ofBook: "a")
        try fixture.database.finishDownload(ofBook: "a", at: fixture.clock.now)
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        try fixture.database.applyLibraryList([], syncedAt: fixture.clock.now)

        #expect(await fixture.outbox().send() == .nothingToSend)
        #expect(fixture.finishedPatches.isEmpty)

        try fixture.database.applyLibraryList([FakeServer.book("a", id: "a")], syncedAt: fixture.clock.now)
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))
        #expect(fixture.serverProgress("a")?.isFinished == true)
    }

    @Test("A Book the Server lost is skipped until the next catalogue sync; the others still go")
    func rejectedBook() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a", "b"])
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        try fixture.database.setFinished(true, ofBook: "b", at: fixture.roundedNow)
        fixture.server.books.removeAll { $0.id == "a" }
        let outbox = fixture.outbox()

        #expect(await outbox.send() == .sent(delivered: 1, rejected: 1))
        #expect(try fixture.database.pendingFinishedChanges().map(\.change.bookID) == ["a"])
        #expect(await outbox.send() == .nothingToSend)

        fixture.server.books.append(FakeServer.book("a", id: "a"))
        await fixture.clock.advance(by: .seconds(1))
        try fixture.database.applyLibraryList(fixture.server.books, syncedAt: fixture.clock.now)
        #expect(await outbox.send() == .sent(delivered: 1, rejected: 0))
        #expect(fixture.serverProgress("a")?.isFinished == true)
    }

    @Test("Offline, the change is kept for the next trigger")
    func keptWhenUnreachable() async throws {
        let fixture = try await SignedInFixture()
        try fixture.haveBooks(["a"])
        try fixture.database.setFinished(true, ofBook: "a", at: fixture.roundedNow)
        fixture.server.isReachable = { _ in false }

        #expect(await fixture.outbox().send() == .unreachable)
        #expect(try fixture.database.pendingFinishedChanges().count == 1)

        fixture.server.isReachable = { _ in true }
        #expect(await fixture.outbox().send() == .sent(delivered: 1, rejected: 0))
    }

    @Test("A Book's offline sessions leave the Server at the latest position, though the first one stamps its time")
    func latestSessionFirst() async throws {
        let fixture = try await SignedInFixture()
        fixture.server.stampsFirstProgressWithServerTime = true
        try fixture.haveBooks(["a"])
        try await fixture.listen("a", from: 100, for: 5)
        await fixture.clock.advance(by: .seconds(20 * 60))  // a long pause: the next listening is a new session
        try await fixture.listen("a", from: 105, for: 60)
        await fixture.clock.advance(by: .seconds(3 * 60 * 60))

        #expect(await fixture.outbox().send() == .sent(delivered: 2, rejected: 0))

        #expect(fixture.serverProgress("a")?.position == 165)
        #expect(try fixture.database.progress(ofBook: "a")?.position == 165)
    }
}
