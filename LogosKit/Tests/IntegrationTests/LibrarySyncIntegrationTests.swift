import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Library sync against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct LibrarySyncIntegrationTests {
    @Test("Signing in, then syncing, fills the Store with every fixture Book, A–Z ignoring a leading article")
    func syncsTheFixtureLibrary() async throws {
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

        #expect(await sync.sync(.launch) == .synced)

        let rows = try database.libraryRows().sortedByTitle()
        #expect(
            rows.map(\.title) == [
                "Between Lights", "The First Light", "The Long Dark", "Loose Parts", "Plain Silence", "Second Dawn",
            ]
        )
        let firstLight = try #require(rows.first { $0.title == "The First Light" })
        #expect(firstLight.authorName == "Ada Fixture")
        #expect(firstLight.narratorName == "Nell Narrator")
        #expect(firstLight.seriesName == "Fixture Saga #1")
        #expect(firstLight.duration == 120)
        #expect(try database.lastLibrarySync() != nil)

        // A second sync with no changes keeps the same Library.
        #expect(await sync.sync(.manual) == .synced)
        #expect(try database.libraryRows().count == 6)
    }
}
