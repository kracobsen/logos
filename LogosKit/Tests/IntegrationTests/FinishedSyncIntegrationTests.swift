import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

/// Uses "Between Lights" (180 s), "The First Light" and "Loose Parts" (120 s): no other suite changes their progress.
@Suite(
    "Finished sync against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh"),
    .serialized
)
struct FinishedSyncIntegrationTests {
    struct Signed {
        let integration: IntegrationServer
        let database: AppDatabase
        let tokens: InMemoryTokenStore
        let identity: ServerIdentity
        let sync: LibrarySync
        let directory: URL

        var token: String {
            get throws { try #require(try tokens.load()).accessToken }
        }

        func bookID(_ title: String) throws -> String {
            try #require(try database.libraryRows().first { $0.title == title }).id
        }

        /// Listening `length` seconds from `position`, starting at `start`, then paused.
        func listen(_ bookID: String, at start: Date, from position: Double, for length: Int) throws {
            for second in 0...length {
                try database.saveProgress(
                    BookProgress(
                        bookID: bookID, position: position + Double(second),
                        lastChanged: start.addingTimeInterval(Double(second)), isFinished: false),
                    listening: second < length)
            }
        }

        /// Sends while the Server can't be reached (an address nothing listens on).
        func sendOffline() async throws -> OutboxSendOutcome {
            try database.saveServerIdentity(
                ServerIdentity(
                    serverURL: URL(string: "http://127.0.0.1:9")!, userID: identity.userID,
                    username: identity.username, libraryID: identity.libraryID, libraryName: identity.libraryName))
            let outcome = await sync.outbox.send()
            try database.saveServerIdentity(identity)
            return outcome
        }

        func serverProgress(_ bookID: String) async throws -> SessionOutboxIntegrationTests.Progress {
            try await integration.get("api/me/progress/\(bookID)", accessToken: token)
        }
    }

    func signIn() async throws -> Signed {
        let integration = try IntegrationServer.current()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let tokens = InMemoryTokenStore()
        let client = AudiobookshelfClient()
        _ = try await SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
            .signIn(
                address: integration.baseURL.absoluteString, username: integration.user.username,
                password: integration.user.password)
        let identity = try #require(try database.serverIdentity())
        let auth = Auth(server: identity.serverURL, api: client, tokenStore: tokens, clock: SystemClock())
        let sync = LibrarySync(database: database, api: client, auth: auth, clock: SystemClock())
        #expect(await sync.sync(.launch) == .synced)
        return Signed(
            integration: integration, database: database, tokens: tokens, identity: identity, sync: sync,
            directory: directory)
    }

    func now(minus seconds: TimeInterval = 0) -> Date {
        Date(millisecondsSince1970: Date().addingTimeInterval(-seconds).millisecondsSince1970)
    }

    @Test("Finished and cleared Finished made offline reach the Server with when the listener acted")
    func offlineFinishedAndCleared() async throws {
        let signed = try await signIn()
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        let book = try signed.bookID("Between Lights")

        // Offline: listening to a Book the Server has no progress for, then marking it Finished. The session creates
        // the Server's progress with the Server's time, later than the Finished change; it still goes through.
        try signed.listen(book, at: now(minus: 300), from: 10, for: 20)
        let finished = now(minus: 200)
        try signed.database.setFinished(true, ofBook: book, at: finished)
        #expect(try await signed.sendOffline() == .unreachable)
        #expect(try signed.database.pendingFinishedChanges().count == 1)

        #expect(await signed.sync.outbox.send() == .sent(delivered: 2, rejected: 0))
        var server = try await signed.serverProgress(book)
        #expect(server.isFinished)
        #expect(server.currentTime == 180)
        #expect(server.lastUpdate == finished.millisecondsSince1970)
        #expect(try signed.database.pendingFinishedChanges().isEmpty)
        #expect(try signed.database.progress(ofBook: book)?.isFinished == true)

        // Offline: clearing Finished.
        let cleared = now(minus: 100)
        try signed.database.setFinished(false, ofBook: book, at: cleared)
        #expect(try await signed.sendOffline() == .unreachable)

        #expect(await signed.sync.outbox.send() == .sent(delivered: 1, rejected: 0))
        server = try await signed.serverProgress(book)
        #expect(!server.isFinished)
        #expect(server.currentTime == 0)
        #expect(server.lastUpdate == cleared.millisecondsSince1970)
        #expect(
            try signed.database.progress(ofBook: book)
                == BookProgress(bookID: book, position: 0, lastChanged: cleared, isFinished: false))
    }

    @Test("A Finished change older than a change made elsewhere is dropped, and the Server's state applied")
    func newerElsewhereWins() async throws {
        let signed = try await signIn()
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        let book = try signed.bookID("The First Light")
        try signed.database.setFinished(true, ofBook: book, at: now(minus: 120))
        // Another device listened since (its first PATCH creates the record with the Server's time, the second keeps
        // the lastUpdate sent).
        let elsewhere = now(minus: 10)
        try await signed.integration.patchProgress(
            of: book, ["currentTime": 42, "lastUpdate": elsewhere.millisecondsSince1970], accessToken: signed.token)
        try await signed.integration.patchProgress(
            of: book, ["currentTime": 42, "lastUpdate": elsewhere.millisecondsSince1970], accessToken: signed.token)

        #expect(await signed.sync.outbox.send() == .sent(delivered: 0, rejected: 0))

        let server = try await signed.serverProgress(book)
        #expect(!server.isFinished)
        #expect(server.currentTime == 42)
        #expect(try signed.database.pendingFinishedChanges().isEmpty)
        #expect(
            try signed.database.progress(ofBook: book)
                == BookProgress(bookID: book, position: 42, lastChanged: elsewhere, isFinished: false))
    }

    @Test("Two offline sessions of a Book without Server progress leave the Server at the latest position")
    func latestSessionFirst() async throws {
        let signed = try await signIn()
        defer { try? FileManager.default.removeItem(at: signed.directory) }
        let book = try signed.bookID("Loose Parts")
        try signed.listen(book, at: now(minus: 40 * 60), from: 0, for: 10)
        try signed.listen(book, at: now(minus: 10 * 60), from: 10, for: 30)  // after a long pause: a new session
        #expect(try signed.database.listeningSessions().count == 2)

        #expect(await signed.sync.outbox.send() == .sent(delivered: 2, rejected: 0))

        #expect(try await signed.serverProgress(book).currentTime == 40)
        #expect(try signed.database.progress(ofBook: book)?.position == 40)
    }
}
