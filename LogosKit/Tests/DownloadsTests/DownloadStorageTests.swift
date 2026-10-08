import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Synchronization
import Testing

/// A volume whose free space the test sets.
final class FakeStorageCapacity: StorageCapacity {
    private let bytes: Mutex<Int64?>

    init(available: Int64? = 100_000_000_000) {
        bytes = Mutex(available)
    }

    var available: Int64? {
        get { bytes.withLock { $0 } }
        set { bytes.withLock { $0 = newValue } }
    }

    func availableForImportantUsage() -> Int64? { available }
}

@Suite("Free space for Downloads")
struct DownloadStorageTests {
    let margin = Downloader.storageMargin

    @Test("Without room for the Book plus the margin, it doesn't start and the queue pauses as Not enough storage")
    func notEnoughStorage() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        fixture.storage.available = margin + 9
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(try fixture.state("a") == .queued)
        #expect(fixture.pending.isEmpty)
        #expect(try fixture.database.downloadPolicy().isPausedForStorage)

        fixture.storage.available = margin + 10
        await downloader.resume()

        #expect(try fixture.state("a") == .downloading)
        #expect(fixture.pending == [transfer("a", "01.mp3")])
        #expect(try !fixture.database.downloadPolicy().isPausedForStorage)
    }

    @Test("A Book tried before needs room only for the files still missing")
    func retryNeedsMissingOnly() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10), ("02.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        fixture.server.failFiles(with: 403)
        await fixture.server.transfers.complete(transfer("a", "02.mp3"))
        fixture.server.beforeHandling(nil)
        fixture.storage.available = margin + 10

        await downloader.download("a")

        #expect(fixture.pending == [transfer("a", "02.mp3")])
    }

    @Test("When a transfer stops and the disk can't hold the rest, the queue pauses without counting an attempt")
    func outOfStorageWhileDownloading() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        fixture.storage.available = 50

        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 40)
        await fixture.clock.advance(by: .seconds(3600))

        #expect(try fixture.database.downloadPolicy().isPausedForStorage)
        #expect(fixture.pending.isEmpty)
        #expect(try fixture.database.downloadFiles(ofBook: "a").first?.attempts == 0)

        fixture.storage.available = margin + 100
        await downloader.resume()

        #expect(try !fixture.database.downloadPolicy().isPausedForStorage)
        #expect(fixture.server.transfers.pending.first?.resumeData == FakeFileTransfers.resumeData(40))
    }

    @Test("When free space can't be read, Downloads go ahead")
    func unknownCapacity() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        fixture.storage.available = nil
        let downloader = await fixture.downloader()

        await downloader.download("a")

        #expect(fixture.pending == [transfer("a", "01.mp3")])
    }
}
