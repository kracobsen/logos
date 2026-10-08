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

    @Test("429 and 5xx answers back off like a dropped transfer", arguments: [429, 500, 503])
    func transientStatuses(status: Int) async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        fixture.server.failFiles(with: status)

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(fixture.pending.isEmpty)
        #expect(try fixture.state("a") == .downloading)
        fixture.server.beforeHandling(nil)
        await fixture.clock.advance(by: .seconds(60))
        await fixture.eventually { !fixture.pending.isEmpty }
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("A 403 fails the Book straight away, and the queue moves on")
    func forbidden() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10), ("02.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        fixture.server.failFiles(with: 403)

        await fixture.server.transfers.complete(transfer("a", "02.mp3"))

        #expect(try fixture.state("a") == .failed)
        #expect(fixture.onDisk("a", "01.mp3")?.count == 10, "completed files are kept")
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("A 404 on a file the Server still lists re-reads the Book and retries once, with the fresh ino")
    func notFoundRetriesOnce() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        // The file moved: the old ino is gone, the Book now lists a new one.
        fixture.server.transfers.stopServing(bookID: "a", ino: "ino-a-01.mp3")
        fixture.server.bookData = [book("a", files: [("01.mp3", 10)], ino: "moved")]
        fixture.server.transfers.serve(Data(count: 10), bookID: "a", ino: "moved")

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(fixture.server.transfers.pending.map(\.ino) == ["moved"], "retried at once")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("A second 404 for the same file fails the Book")
    func notFoundTwice() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")
        fixture.server.transfers.stopServing(bookID: "a", ino: "ino-a-01.mp3")

        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloading)
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .failed)
        #expect(fixture.pending == [transfer("b", "01.mp3")])
    }

    @Test("A 404 for a file the re-read Book no longer lists drops that file; the rest finish the Book")
    func notFoundFileGone() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10), ("02.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        fixture.server.transfers.stopServing(bookID: "a", ino: "ino-a-02.mp3")
        fixture.server.bookData = [book("a", files: [("01.mp3", 10)])]

        await fixture.server.transfers.complete(transfer("a", "02.mp3"))
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .downloaded)
        #expect(try fixture.database.downloadFiles(ofBook: "a").map(\.relPath) == ["01.mp3"])
    }

    @Test("Retry after a failure fetches only the files still missing")
    func retryFetchesMissingOnly() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10), ("02.mp3", 10)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        fixture.server.failFiles(with: 403)
        await fixture.server.transfers.complete(transfer("a", "02.mp3"))
        #expect(try fixture.state("a") == .failed)
        fixture.server.beforeHandling(nil)

        await downloader.download("a")

        #expect(fixture.pending == [transfer("a", "02.mp3")])
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("Retry starts the Book's attempts afresh: one dropped transfer after it backs off instead of failing")
    func retryResetsAttempts() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100)])])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        for minutes in [1, 5, 30, 30] {
            await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 10)
            await fixture.clock.advance(by: .seconds(minutes * 60))
            await fixture.eventually { !fixture.pending.isEmpty }
        }
        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 10)
        #expect(try fixture.state("a") == .failed)

        await downloader.download("a")
        await fixture.server.transfers.interrupt(transfer("a", "01.mp3"), receivedBytes: 20)

        #expect(try fixture.state("a") == .downloading)
        await fixture.clock.advance(by: .seconds(60))
        await fixture.eventually { !fixture.pending.isEmpty }
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
    }

    @Test("Retry forgets earlier wrong-size arrivals: one more after it starts the file again instead of failing")
    func retryResetsSizeMismatches() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10)])])
        fixture.server.transfers.serve(Data(count: 9), bookID: "a", ino: "ino-a-01.mp3")
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .failed)

        await downloader.download("a")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(try fixture.state("a") == .downloading)
        fixture.server.transfers.serve(Data(count: 10), bookID: "a", ino: "ino-a-01.mp3")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(try fixture.state("a") == .downloaded)
    }
}

extension FakeServer {
    /// Answers every file transfer with `status` (until `beforeHandling(nil)`).
    func failFiles(with status: Int) {
        beforeHandling { request throws(ServerAPIError) in
            guard case .file = request else { return }
            throw status == 429 ? .rateLimited : .unexpectedStatus(status)
        }
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
