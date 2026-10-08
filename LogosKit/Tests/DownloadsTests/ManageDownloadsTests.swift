import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing

@Suite("Managing Downloads")
struct ManageDownloadsTests {
    @Test("Reordering the queue changes which Book starts next")
    func reorder() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]), book("c", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        for id in ["a", "b", "c"] { await downloader.download(id) }

        await downloader.reorder(["c", "b"])
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))

        #expect(fixture.pending == [transfer("c", "01.mp3")])
        #expect(try fixture.state("b") == .queued)
    }

    @Test("Cancelling a queued Book takes it out of the queue and leaves the active one alone")
    func cancelQueued() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")

        await downloader.cancel("b")

        #expect(try fixture.state("b") == nil)
        #expect(fixture.pending == [transfer("a", "01.mp3")])
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
        #expect(try fixture.state("b") == nil)
    }

    @Test("Removing a downloaded Book deletes every file at once and keeps the Book and its progress")
    func remove() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10), ("CD 2/02.mp3", 20)], cover: true)
        ])
        fixture.server.covers = ["a": Data("cover".utf8)]
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.completeAll()
        let progress = BookProgress(bookID: "a", position: 12, lastChanged: fixture.clock.now, isFinished: false)
        try fixture.database.saveProgress(progress)

        await downloader.cancel("a")

        #expect(try fixture.state("a") == nil)
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.files.folder(forBook: "a").path(percentEncoded: false)))
        #expect(try fixture.database.bookIDs() == ["a"])
        #expect(try fixture.database.progress(ofBook: "a") == progress)
        #expect(fixture.covers.exists(forBook: "a"))
    }

    @Test("Removing the Download of a Not on Server Book deletes the Book, its progress and its cover")
    func removeNotOnServer() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10)], cover: true), book("b", files: [("01.mp3", 10)]),
        ])
        fixture.server.covers = ["a": Data("cover".utf8)]
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await fixture.server.transfers.completeAll()
        try fixture.database.saveProgress(
            BookProgress(bookID: "a", position: 12, lastChanged: fixture.clock.now, isFinished: false))
        try fixture.database.applyLibraryList([book("b", files: []).book], syncedAt: fixture.clock.now)
        #expect(try fixture.database.bookDetail(id: "a")?.isNotOnServer == true)

        await downloader.cancel("a")

        #expect(try fixture.database.bookIDs() == ["b"])
        #expect(try fixture.database.progress(ofBook: "a") == nil)
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(!fixture.covers.exists(forBook: "a"))
    }

    @Test("The launch file check marks a Download with a missing file not downloaded, without queueing it again")
    func launchFileCheck() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 10), ("02.mp3", 10)])])
        let before = await fixture.downloader()
        await before.download("a")
        await fixture.server.transfers.completeAll()
        #expect(try fixture.state("a") == .downloaded)
        try FileManager.default.removeItem(at: fixture.files.url(forBook: "a", relPath: "02.mp3"))
        let enqueuedBefore = fixture.server.transfers.enqueued.count

        let downloader = await fixture.downloader(inForeground: false)
        await downloader.checkFiles()
        await downloader.resume()

        #expect(try fixture.state("a") == nil)
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(fixture.server.transfers.enqueued.count == enqueuedBefore)
    }

    @Test("A downloading Book the Server no longer lists: its transfers stop, its files go, and the next Book starts")
    func downloadingBookLeavesLibrary() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 10), ("02.mp3", 10)]), book("b", files: [("01.mp3", 10)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("a")
        await downloader.download("b")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        #expect(fixture.onDisk("a", "01.mp3") != nil)
        #expect(fixture.pending == [transfer("a", "02.mp3")])

        try fixture.database.applyLibraryList([book("b", files: []).book], syncedAt: fixture.clock.now)
        await fixture.eventually { fixture.pending == [transfer("b", "01.mp3")] }

        #expect(fixture.pending == [transfer("b", "01.mp3")])
        #expect(fixture.onDisk("a", "01.mp3") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.files.folder(forBook: "a").path(percentEncoded: false)))
        #expect(try fixture.state("b") == .downloading)
    }
}
