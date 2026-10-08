import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing

@Suite("Downloads and the network")
struct DownloadNetworkTests {
    @Test("Downloads are Wi-Fi only by default: the transfers are kept off cellular from the start")
    func wifiOnlyByDefault() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])

        _ = await fixture.downloader()

        #expect(fixture.server.transfers.allowsCellularAccess == false)
    }

    @Test("Allowing cellular is saved and applied to the transfers, including after a relaunch")
    func allowCellular() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")

        await downloader.setAllowsCellular(true)

        #expect(try fixture.database.downloadPolicy().allowsCellular)
        #expect(fixture.server.transfers.allowsCellularAccess == true)
        #expect(fixture.pending == [transfer("a", "01.mp3")], "the running transfer carries on")

        fixture.server.transfers.allowsCellularAccess = false  // a new process starts Wi-Fi only
        _ = await fixture.downloader()
        #expect(fixture.server.transfers.allowsCellularAccess == true)
    }

    @Test("Turning cellular off again keeps Downloads off cellular")
    func disallowCellular() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.setAllowsCellular(true)

        await downloader.setAllowsCellular(false)

        #expect(try !fixture.database.downloadPolicy().allowsCellular)
        #expect(fixture.server.transfers.allowsCellularAccess == false)
    }
}
