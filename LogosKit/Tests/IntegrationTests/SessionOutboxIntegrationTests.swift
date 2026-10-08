import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Listening sessions against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh"),
    .serialized
)
struct SessionOutboxIntegrationTests {
    /// One session in the Server's listening history (`GET /api/me/item/listening-sessions/:id`).
    struct HistorySession: Decodable {
        struct Device: Decodable {
            let clientName: String?
            let deviceId: String?
        }
        let id: String
        let libraryItemId: String
        let startTime: Double
        let currentTime: Double
        let timeListening: Double
        let startedAt: Int64
        let updatedAt: Int64
        let date: String?
        let deviceInfo: Device?
    }

    struct Progress: Decodable {
        let currentTime: Double
        let lastUpdate: Int64
        let isFinished: Bool
    }

    @Test(
        "Listening offline is kept, then sent on reconnecting with its original times; the Server's progress and history match"
    )
    func offlineThenReconnect() async throws {
        let integration = try IntegrationServer.current()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
        let book = try #require(try database.libraryRows().first { $0.title == "Second Dawn" })
        // A Book the Library had at the last sync that the Server has since lost: its session fails on its own.
        var listed = try await client.books(
            inLibrary: identity.libraryID, on: identity.serverURL, accessToken: #require(try tokens.load()).accessToken)
        let lostID = UUID().uuidString.lowercased()
        listed.append(
            ListedBook(
                id: lostID, mediaID: UUID().uuidString.lowercased(), title: "Lost", subtitle: nil, authorName: "",
                authorNameLF: "", narratorName: "", seriesName: "", description: nil, publishedYear: nil, genres: [],
                addedAt: Date(), updatedAt: 0, duration: 60, size: 1, hasCover: false))
        try database.applyLibraryList(listed, syncedAt: Date())

        // Another device listened an hour ago (a record's first write gets the Server's time; later ones keep the
        // lastUpdate sent).
        let token = try #require(try tokens.load()).accessToken
        try await integration.patchProgress(of: book.id, ["currentTime": 5], accessToken: token)
        try await integration.patchProgress(
            of: book.id, ["currentTime": 5, "lastUpdate": Date().addingTimeInterval(-3600).millisecondsSince1970],
            accessToken: token)

        // Five minutes ago, offline: 20 s from 10 s, a one-minute pause (the same session), 20 s more.
        let started = Date(millisecondsSince1970: Date().addingTimeInterval(-5 * 60).millisecondsSince1970)
        func listen(_ bookID: String, at seconds: Double, from position: Double, for length: Int) throws {
            for second in 0...length {
                try database.saveProgress(
                    BookProgress(
                        bookID: bookID, position: position + Double(second),
                        lastChanged: started.addingTimeInterval(seconds + Double(second)), isFinished: false),
                    listening: second < length)
            }
        }
        try listen(book.id, at: 0, from: 10, for: 20)
        try listen(book.id, at: 80, from: 30, for: 20)
        let pausedAt = started.addingTimeInterval(100)
        let session = try #require(try database.listeningSessions().first)
        #expect(try database.listeningSessions().count == 1)

        // Still offline: nothing is delivered and nothing is lost.
        let offline = ServerIdentity(
            serverURL: URL(string: "http://127.0.0.1:9")!, userID: identity.userID, username: identity.username,
            libraryID: identity.libraryID, libraryName: identity.libraryName)
        try database.saveServerIdentity(offline)
        #expect(await sync.outbox.send() == .unreachable)
        #expect(try database.unsentListeningSessions().count == 1)

        // Reconnected: sent with the times the listening happened.
        try database.saveServerIdentity(identity)
        #expect(await sync.outbox.send() == .sent(delivered: 1, rejected: 0))

        var progress: Progress = try await integration.get("api/me/progress/\(book.id)", accessToken: token)
        #expect(progress.currentTime == 50)
        #expect(progress.lastUpdate == pausedAt.millisecondsSince1970)
        #expect(!progress.isFinished)
        var sent = try await integration.history(of: book.id, session: session.serverID, accessToken: token)
        #expect(sent.count == 1)
        #expect(sent.first?.libraryItemId == book.id)
        #expect(sent.first?.startTime == 10)
        #expect(sent.first?.currentTime == 50)
        #expect(sent.first?.timeListening == 40)
        #expect(sent.first?.startedAt == started.millisecondsSince1970)
        #expect(sent.first?.updatedAt == pausedAt.millisecondsSince1970)
        #expect(sent.first?.date != nil)
        #expect(sent.first?.deviceInfo?.clientName == "Logos")
        #expect(sent.first?.deviceInfo?.deviceId == (try database.clientDeviceID()))
        // The progress fetch after the send left the local progress as it was (same time, same place).
        #expect(
            try database.progress(ofBook: book.id)
                == BookProgress(bookID: book.id, position: 50, lastChanged: pausedAt, isFinished: false))

        // Playing on within 10 minutes continues the session: resending it updates the one on the Server.
        try listen(book.id, at: 200, from: 50, for: 10)
        #expect(await sync.outbox.send() == .sent(delivered: 1, rejected: 0))
        sent = try await integration.history(of: book.id, session: session.serverID, accessToken: token)
        #expect(sent.count == 1)
        #expect(sent.first?.currentTime == 60)
        #expect(sent.first?.timeListening == 50)
        progress = try await integration.get("api/me/progress/\(book.id)", accessToken: token)
        #expect(progress.currentTime == 60)

        // Listening to the lost Book ends this session; its state was already confirmed, so it leaves the outbox.
        // The lost Book's session fails on its own and is kept, skipped until the next catalogue sync.
        try listen(lostID, at: 250, from: 0, for: 5)
        #expect(await sync.outbox.send() == .sent(delivered: 0, rejected: 1))
        #expect(try database.listeningSessions().map(\.bookID) == [lostID])
        #expect(await sync.outbox.send() == .nothingToSend)
    }
}

extension IntegrationServer {
    /// An authenticated GET, decoded.
    func get<T: Decodable>(_ path: String, accessToken: String) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The copies of one session in a Book's listening history.
    func history(of bookID: String, session id: String, accessToken: String) async throws
        -> [SessionOutboxIntegrationTests.HistorySession]
    {
        struct History: Decodable { let sessions: [SessionOutboxIntegrationTests.HistorySession] }
        let history: History = try await get(
            "api/me/item/listening-sessions/\(bookID)", accessToken: accessToken)
        return history.sessions.filter { $0.id == id }
    }
}
