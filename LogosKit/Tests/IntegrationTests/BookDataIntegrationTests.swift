import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite(
    "Full Book data against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct BookDataIntegrationTests {
    /// A signed-in Store and sync against the Docker Server.
    struct Session {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let database: AppDatabase
        let client = AudiobookshelfClient()
        let auth: Auth
        let sync: LibrarySync

        init() async throws {
            let server = try IntegrationServer.current()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
            let tokens = InMemoryTokenStore()
            _ = try await SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
                .signIn(
                    address: server.baseURL.absoluteString, username: server.user.username,
                    password: server.user.password)
            let identity = try #require(try database.serverIdentity())
            auth = Auth(server: identity.serverURL, api: client, tokenStore: tokens, clock: SystemClock())
            sync = LibrarySync(database: database, api: client, auth: auth, clock: SystemClock())
        }

        func detail(_ title: String) throws -> BookDetail {
            let row = try #require(try database.libraryRows().first { $0.title == title })
            return try #require(try database.bookDetail(id: row.id))
        }
    }

    @Test("A sync fetches every fixture Book's Chapters, tracks and Series via batch/get")
    func syncFetchesFullData() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        #expect(await session.sync.sync(.launch) == .synced)

        #expect(try session.database.booksBehindOnFullData().isEmpty)
        let firstLight = try session.detail("The First Light")
        #expect(firstLight.chapters.chapters.map(\.title) == ["Dawn", "Noon", "Dusk"])
        #expect(firstLight.tracks.map(\.relPath) == ["01.mp3"])
        #expect(firstLight.tracks.first?.size == firstLight.size)
        #expect(firstLight.series.map(\.name) == ["Fixture Saga"])
        #expect(firstLight.series.map(\.sequence) == ["1"])

        let between = try session.detail("Between Lights")
        #expect(between.chapters.count == 4)
        #expect(between.tracks.map(\.relPath) == ["01.mp3", "02.mp3", "03.mp3"])
        #expect(between.tracks.map(\.startOffset) == [0, 60, 120])
        #expect(between.series.map(\.sequence) == ["1.5"])

        #expect(try session.detail("The Long Dark").series.map(\.sequence) == [nil])

        let plain = try session.detail("Plain Silence")
        #expect(plain.chapters.chapters.map(\.title) == ["Plain Silence"])
        #expect(plain.series.isEmpty)
        #expect(plain.hasCurrentFullData)

        #expect(try session.detail("Loose Parts").chapters.chapters.map(\.title) == ["01", "02"])
    }

    @Test("A detail opened before stage 2 fetches its Book alone, via items/:id?expanded=1")
    func detailFetchesOneBook() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let identity = try #require(try session.database.serverIdentity())
        let api = session.client
        let books = try await session.auth.authorized { token throws(ServerAPIError) in
            try await api.books(inLibrary: identity.libraryID, on: identity.serverURL, accessToken: token)
        }
        try session.database.applyLibraryList(books, syncedAt: .now)
        #expect(try session.detail("Second Dawn").hasCurrentFullData == false)

        let row = try #require(try session.database.libraryRows().first { $0.title == "Second Dawn" })
        await session.sync.fetchFullDataNow(ofBook: row.id)

        let detail = try session.detail("Second Dawn")
        #expect(detail.hasCurrentFullData)
        #expect(detail.chapters.chapters.map(\.title) == ["Before", "After"])
        #expect(try session.database.booksBehindOnFullData().count == 5)
    }

    @Test("batch/get leaves out ids the Server doesn't know")
    func batchOmitsUnknown() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let identity = try #require(try session.database.serverIdentity())
        let api = session.client
        let books = try await session.auth.authorized { token throws(ServerAPIError) in
            try await api.books(inLibrary: identity.libraryID, on: identity.serverURL, accessToken: token)
        }
        let known = try #require(books.first)

        let fetched = try await session.auth.authorized { token throws(ServerAPIError) in
            try await api.bookData(
                for: [known.id, "00000000-0000-0000-0000-000000000000"], on: identity.serverURL, accessToken: token)
        }

        #expect(fetched.map(\.book.id) == [known.id])
    }
}
