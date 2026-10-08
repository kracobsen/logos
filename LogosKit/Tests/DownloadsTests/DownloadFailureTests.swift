import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing

@Suite("Download failures")
struct DownloadFailureTests {
    @Test("A dropped transfer is retried after about 1, 5, 30 and 30 minutes; the 5th failure fails the Book")
    func backoffSchedule() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 100)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")

        for (attempt, minutes) in [1, 5, 30, 30].enumerated() {
            await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: Int64(10 * attempt + 10))
            #expect(fixture.pending.isEmpty, "no retry before the backoff, after failure \(attempt + 1)")
            await fixture.clock.advance(by: .seconds(minutes * 60 - 1))
            #expect(fixture.pending.isEmpty, "still waiting a second before \(minutes) min")
            await fixture.clock.advance(by: .seconds(1))
            await fixture.eventually { !fixture.pending.isEmpty }
            let retried = try #require(fixture.server.transfers.pending.first, "retried after failure \(attempt + 1)")
            #expect(retried.transfer == transfer("a", "01.mp3"))
            #expect(retried.resumeData == FakeFileTransfers.resumeData(Int64(10 * attempt + 10)))
            #expect(try fixture.state("a") == .downloading)
        }

        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 60)

        #expect(try fixture.state("a") == .failed)
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }
}

extension DownloadsFixture {
    /// Waits (up to 2 s) for work that a clock tick set off in another task.
    func eventually(_ condition: () throws -> Bool) async rethrows {
        for _ in 0..<200 {
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
