import Domain
import Foundation
import ServerAPI
import Store
import Testing
import UI

extension DownloadsModelTests {
    @Test("Moving a queued row reorders the queue at once; the active Book stays first")
    func moveQueued() async throws {
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        for id in ["first", "second", "third"] { await model.download(id) }
        await eventually { model.list.queue.count == 3 }

        await model.moveQueued(fromOffsets: [2], toOffset: 0)

        #expect(model.list.queue.map(\.id) == ["first", "third", "second"])
        #expect(try database.downloadQueue() == ["first", "third", "second"])
    }

    @Test("Downloaded Books show most recently listened first, or largest first")
    func order() async throws {
        server.transfers.serve(Data(count: 3000), bookID: "third", ino: "ino-third")
        let big = AudioTrack(
            index: 1, ino: "ino-third", relPath: "01.mp3", size: 3000, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg")
        server.bookData = server.bookData.map {
            $0.book.id == "third" ? BookData(book: $0.book, chapters: [], tracks: [big], series: $0.series) : $0
        }
        for id in ["first", "second", "third"] { await downloader.download(id) }
        await server.transfers.completeAll()
        try database.saveProgress(
            BookProgress(bookID: "second", position: 5, lastChanged: clock.now, isFinished: false))
        let model = model()
        #expect(model.order == .recentlyListened)
        #expect(model.downloaded.map(\.id) == ["second", "first", "third"])

        model.order = .largestFirst

        #expect(model.downloaded.map(\.id) == ["third", "second", "first"])
    }

    @Test("Removing a downloaded Book takes it off the Downloaded tab and keeps it in the Library")
    func remove() async throws {
        await downloader.download("first")
        await server.transfers.completeAll()
        let model = model()
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        await model.cancel("first")

        // The list and the statuses are separate observations: wait for both to land.
        await eventually {
            model.list.downloaded.isEmpty && model.action(forBook: "first", size: 1000) != .downloaded
        }
        #expect(model.list.downloaded.isEmpty)
        #expect(model.action(forBook: "first", size: 1000) != .downloaded)
        #expect(try database.bookIDs().contains("first"))
    }
}
