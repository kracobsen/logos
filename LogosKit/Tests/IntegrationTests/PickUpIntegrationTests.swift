import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

// In the progress suite, which runs serialized: both tests change and fetch the same user's progress.
extension ProgressIntegrationTests {
    @Test(
        "A newer position from another device is reported to the player once, and a near-identical one isn't",
        .timeLimit(.minutes(1)))
    func reportsPickUps() async throws {
        let server = try IntegrationServer.current()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let tokens = InMemoryTokenStore()
        let client = AudiobookshelfClient()
        _ = try await SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
            .signIn(
                address: server.baseURL.absoluteString, username: server.user.username, password: server.user.password)
        let identity = try #require(try database.serverIdentity())
        let auth = Auth(server: identity.serverURL, api: client, tokenStore: tokens, clock: SystemClock())
        let sync = LibrarySync(database: database, api: client, auth: auth, clock: SystemClock())
        let accessToken = try #require(try tokens.load()).accessToken
        #expect(await sync.sync(.launch) == .synced)
        let book = try #require(try database.libraryRows().first { $0.title == "Second Dawn" })
        let now = Date().millisecondsSince1970
        try database.saveProgress(
            BookProgress(
                bookID: book.id, position: 10, lastChanged: Date(millisecondsSince1970: now - 120_000),
                isFinished: false))
        var pickUps = database.fetchedProgressUpdates().makeAsyncIterator()

        // Another device listened on to 90 s a minute ago.
        try await server.patchProgress(of: book.id, ["currentTime": 30], accessToken: accessToken)
        try await server.patchProgress(
            of: book.id, ["currentTime": 90, "lastUpdate": now - 60_000], accessToken: accessToken)
        #expect(await sync.progress.fetch() == .fetched(changedBookIDs: [book.id]))

        // Then nudged it by a second: newer, but no real change.
        try await server.patchProgress(
            of: book.id, ["currentTime": 91, "lastUpdate": now - 30_000], accessToken: accessToken)
        #expect(await sync.progress.fetch() == .fetched(changedBookIDs: []))
        // And moved on for real.
        try await server.patchProgress(
            of: book.id, ["currentTime": 110, "lastUpdate": now - 10_000], accessToken: accessToken)
        #expect(await sync.progress.fetch() == .fetched(changedBookIDs: [book.id]))

        var picked: [Double] = []
        while picked.count < 2, let adopted = await pickUps.next() {
            picked += adopted.filter { $0.bookID == book.id }.map(\.position)
        }
        #expect(picked == [90, 110])
    }
}
