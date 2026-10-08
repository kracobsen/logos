import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Sync
import Synchronization
import Testing

@Suite(
    "Downloads against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh"),
    .serialized
)
struct DownloadsIntegrationTests {
    /// A signed-in, synced Store with Downloads through a real URLSession (not a background one: the test process
    /// isn't an app). The delegate code is the same.
    struct Session {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let database: AppDatabase
        let client = AudiobookshelfClient()
        let tokens = InMemoryTokenStore()
        let auth: Auth
        let transfers = BackgroundFileTransfers(configuration: .ephemeral)
        let files: DownloadFiles
        let covers: CoverFiles
        let downloader: Downloader
        let server: URL

        init() async throws {
            let integration = try IntegrationServer.current()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
            _ = try await SignIn(api: client, tokenStore: tokens, database: database, allowsPlainHTTPOnLoopback: true)
                .signIn(
                    address: integration.baseURL.absoluteString, username: integration.user.username,
                    password: integration.user.password)
            server = try #require(try database.serverIdentity()).serverURL
            auth = Auth(server: server, api: client, tokenStore: tokens, clock: SystemClock())
            #expect(
                await LibrarySync(database: database, api: client, auth: auth, clock: SystemClock()).sync(.launch)
                    == .synced)
            files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
            covers = try CoverFiles(directory: directory.appending(path: "Covers"))
            downloader = Downloader(
                database: database, api: client, auth: auth, transfers: transfers, files: files, covers: covers,
                clock: SystemClock())
            await downloader.start()
        }

        func bookID(_ title: String) throws -> String {
            try #require(try database.libraryRows().first { $0.title == title }).id
        }

        /// Waits (up to 30 s) for the Book's Download to reach `state`.
        func waitFor(_ state: DownloadState, _ bookID: String) async throws {
            for _ in 0..<300 {
                if try database.downloadStatus(ofBook: bookID)?.state == state { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("still \(String(describing: try database.downloadStatus(ofBook: bookID)?.state))")
        }
    }

    @Test("A multi-file Book downloads whole: every file at its size on disk, verified")
    func multiFileBook() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let id = try session.bookID("Between Lights")

        await session.downloader.download(id)
        try await session.waitFor(.downloaded, id)

        let tracks = try #require(try session.database.bookDetail(id: id)).tracks
        #expect(tracks.count == 3)
        for track in tracks {
            #expect(session.files.size(ofBook: id, relPath: track.relPath) == track.size)
        }
        #expect(try session.database.downloadFiles(ofBook: id).allSatisfy(\.isVerified))
    }

    @Test("Books download in order, and a Book's cover is fetched into the shared cover file")
    func queueAndCover() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let first = try session.bookID("The First Light")
        let second = try session.bookID("Loose Parts")

        await session.downloader.download(first)
        await session.downloader.download(second)
        try await session.waitFor(.downloaded, second)

        #expect(try session.database.downloadStatus(ofBook: first)?.state == .downloaded)
        #expect(session.covers.exists(forBook: first))
        #expect(try session.database.downloadsList().downloaded.count == 2)
    }

    @Test("The real transfers report 401 for a rejected token and 404 for an unknown ino, and keep no file")
    func statuses() async throws {
        let session = try await Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        let id = try session.bookID("Plain Silence")
        let track = try #require(try session.database.bookDetail(id: id)?.tracks.first)
        let events = Mutex<[FileTransferEvent]>([])
        let transfers = BackgroundFileTransfers(configuration: .ephemeral)
        await transfers.setEventHandler { event in
            if case .progress = event { return }
            events.withLock { $0.append(event) }
        }
        let token = try await session.auth.accessToken(validFor: .seconds(60))
        let destination = session.files.url(forBook: id, relPath: track.relPath)

        await transfers.enqueue(
            FileTransferRequest(
                transfer: FileTransfer(bookID: id, relPath: "bad-token"), ino: track.ino, server: session.server,
                accessToken: "not-a-token", destination: destination))
        await transfers.enqueue(
            FileTransferRequest(
                transfer: FileTransfer(bookID: id, relPath: "bad-ino"), ino: "1", server: session.server,
                accessToken: token, destination: destination))
        for _ in 0..<100 where events.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }

        let statuses = events.withLock { events in
            Dictionary(
                uniqueKeysWithValues: events.compactMap { event -> (String, Int)? in
                    guard case .finished(let transfer, let status, _) = event else { return nil }
                    return (transfer.relPath, status)
                })
        }
        #expect(statuses == ["bad-token": 401, "bad-ino": 404])
        #expect(session.files.size(ofBook: id, relPath: track.relPath) == nil)
    }
}
