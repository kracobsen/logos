import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing
import UI

/// A network whose Wi-Fi the test switches on and off.
final class FakeNetwork: NetworkMonitor {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
    }

    func set(wifi: Bool) { continuation.yield(wifi) }

    func wifiUpdates() -> AsyncStream<Bool> { stream }
}

@Suite("Download notices and the cellular setting")
@MainActor
struct DownloadNoticeTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let network = FakeNetwork()

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(
            [FakeServer.book("First", id: "first"), FakeServer.book("Second", id: "second")], syncedAt: clock.now)
    }

    func observed() -> (DownloadsModel, Task<Void, Never>) {
        let model = DownloadsModel(database: database, downloader: nil, network: network)
        return (model, Task { await model.observe() })
    }

    /// Waits (up to 10 s: these run alongside every other suite) for the model to follow the database.
    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Off Wi-Fi with cellular not allowed, waiting Books show Waiting for Wi-Fi; back on Wi-Fi, they don't")
    func waitingForWiFi() async throws {
        try database.queueDownload(ofBook: "first")
        let (model, observing) = observed()
        defer { observing.cancel() }

        network.set(wifi: false)
        await eventually { model.notice != nil }
        #expect(model.notice == .waitingForWiFi)
        #expect(model.notice?.text == "Waiting for Wi-Fi")

        network.set(wifi: true)
        await eventually { model.notice == nil }
        #expect(model.notice == nil)
    }

    @Test("With cellular allowed, nothing waits for Wi-Fi")
    func cellularAllowed() async throws {
        try database.queueDownload(ofBook: "first")
        try database.setAllowsCellularDownloads(true)
        let (model, observing) = observed()
        defer { observing.cancel() }

        network.set(wifi: false)
        await eventually { !model.isOnWiFi }

        #expect(!model.isOnWiFi)
        #expect(model.notice == nil)
    }

    @Test("With nothing in the queue there's no notice, even off Wi-Fi")
    func emptyQueue() async throws {
        let (model, observing) = observed()
        defer { observing.cancel() }

        network.set(wifi: false)
        await eventually { !model.isOnWiFi }

        #expect(!model.isOnWiFi)
        #expect(model.notice == nil)
    }

    @Test("A queue paused for storage shows Not enough storage")
    func notEnoughStorage() async throws {
        try database.queueDownload(ofBook: "first")
        let (model, observing) = observed()
        defer { observing.cancel() }

        try database.setDownloadsPausedForStorage(true)

        await eventually { model.notice != nil }
        #expect(model.notice == .notEnoughStorage)
        #expect(model.notice?.text == "Not enough storage")
    }

    @Test("Settings shows the stored cellular setting; changing it saves it and applies it to the transfers")
    func settingsToggle() async throws {
        let server = FakeServer(clock: clock)
        let downloader = Downloader(
            database: database, api: server,
            auth: Auth(server: server.address, api: server, tokenStore: InMemoryTokenStore(), clock: clock),
            transfers: server.transfers, files: try DownloadFiles(directory: directory.appending(path: "Downloads")),
            covers: nil, clock: clock)
        let settings = SettingsModel(database: database, downloader: downloader)
        #expect(!settings.allowsCellular)

        await settings.setAllowsCellular(true)

        #expect(settings.allowsCellular)
        #expect(try database.downloadPolicy().allowsCellular)
        #expect(server.transfers.allowsCellularAccess)
        #expect(SettingsModel(database: database, downloader: nil).allowsCellular)
    }
}
