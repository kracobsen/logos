import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Progress fetch against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh"),
    .serialized
)
struct ProgressIntegrationTests {
    @Test("Progress made on another device is picked up by the sync, and newer local progress is kept")
    func picksUpProgress() async throws {
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
        let books = try await client.books(
            inLibrary: identity.libraryID, on: identity.serverURL, accessToken: accessToken)
        let book = try #require(books.first { $0.title == "The Long Dark" })

        // Another device listens to 30 s, then to 45 s with a known lastUpdate (a record's first write gets the
        // Server's time; later ones keep the lastUpdate sent).
        try await server.patchProgress(of: book.id, ["currentTime": 30], accessToken: accessToken)
        let lastUpdate = Date().addingTimeInterval(-60).millisecondsSince1970
        try await server.patchProgress(
            of: book.id, ["currentTime": 45, "lastUpdate": lastUpdate], accessToken: accessToken)

        #expect(await sync.sync(.launch) == .synced)
        #expect(
            try database.progress(ofBook: book.id)
                == BookProgress(
                    bookID: book.id, position: 45, lastChanged: Date(millisecondsSince1970: lastUpdate),
                    isFinished: false))
        // Other tests in this suite leave other Books in progress on the shared Server.
        #expect(try database.inProgressRows().map(\.id).contains(book.id))

        // Listening here afterwards is newer, so the next fetch keeps it.
        let local = BookProgress(
            bookID: book.id, position: 70, lastChanged: Date(millisecondsSince1970: Date().millisecondsSince1970),
            isFinished: false)
        try database.saveProgress(local)
        #expect(await sync.progress.fetch() == .fetched(changedBookIDs: []))
        #expect(try database.progress(ofBook: book.id) == local)
    }
}

extension IntegrationServer {
    /// `PATCH /api/me/progress/:id` as another device would send it.
    func patchProgress(of bookID: String, _ body: [String: Any], accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/me/progress").appending(path: bookID))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
