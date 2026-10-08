import Domain
import Foundation
import ImageIO
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Cover sync against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct CoverSyncIntegrationTests {
    @Test("A sync stores The First Light's cover as a JPEG of at most 600 px, and no file for the Books without one")
    func syncsCovers() async throws {
        let server = try IntegrationServer.current()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        let covers = try CoverFiles(directory: directory.appending(path: "Covers"))
        let tokens = InMemoryTokenStore()
        let client = AudiobookshelfClient()
        _ = try await SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
            .signIn(
                address: server.baseURL.absoluteString, username: server.user.username, password: server.user.password)
        let identity = try #require(try database.serverIdentity())
        let auth = Auth(server: identity.serverURL, api: client, tokenStore: tokens, clock: SystemClock())
        let sync = LibrarySync(database: database, api: client, auth: auth, clock: SystemClock(), covers: covers)

        #expect(await sync.sync(.launch) == .synced)

        let firstLight = try #require(try database.libraryRows().first { $0.title == "The First Light" })
        #expect(try covers.bookIDs() == [firstLight.id])
        let source = try #require(CGImageSourceCreateWithURL(covers.url(forBook: firstLight.id) as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        #expect(width > 0 && width <= 600)
        #expect(try database.coversBehind().isEmpty)
        #expect(try database.coverVersions().keys.sorted() == [firstLight.id])
    }
}
