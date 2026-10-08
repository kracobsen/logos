import Domain
import Foundation
import Store
import Testing

@Suite("The Download queue in the Store")
struct DownloadStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open(books: [String] = ["a", "b", "c"]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: url)
        try database.applyLibraryList(books.map { listedBook($0.uppercased(), id: $0) }, syncedAt: now)
        return database
    }

    func track(_ relPath: String, size: Int64) -> AudioTrack {
        AudioTrack(
            index: 1, ino: "ino-\(relPath)", relPath: relPath, size: size, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg")
    }

    @Test("Queued Books keep the order they were asked for, and survive reopening the database")
    func fifo() throws {
        let database = try open()
        try database.queueDownload(ofBook: "b")
        try database.queueDownload(ofBook: "a")
        try database.queueDownload(ofBook: "c")

        let reopened = try AppDatabase.open(at: url)

        #expect(try reopened.downloadQueue() == ["b", "a", "c"])
    }

    @Test("Queueing a Book that's already queued keeps its place")
    func queueTwice() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        try database.queueDownload(ofBook: "b")
        try database.queueDownload(ofBook: "a")

        #expect(try database.downloadQueue() == ["a", "b"])
    }

    @Test("Only one Book is active: the first in the queue, until it's done")
    func oneActive() throws {
        let database = try open()
        try database.queueDownload(ofBook: "b")
        try database.queueDownload(ofBook: "a")

        #expect(try database.startNextDownload() == "b")
        #expect(try database.startNextDownload() == "b")
        #expect(try database.downloadStatus(ofBook: "b")?.state == .downloading)
        #expect(try database.downloadStatus(ofBook: "a")?.state == .queued)

        try database.finishDownload(ofBook: "b", at: now)

        #expect(try database.downloadStatus(ofBook: "b")?.state == .downloaded)
        #expect(try database.downloadQueue() == ["a"])
        #expect(try database.startNextDownload() == "a")
        try database.failDownload(ofBook: "a")
        #expect(try database.startNextDownload() == nil)
        #expect(try database.downloadStatus(ofBook: "a")?.state == .failed)
    }

    @Test("A failed Book queued again goes to the end of the queue")
    func requeueFailed() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        _ = try database.startNextDownload()
        try database.failDownload(ofBook: "a")
        try database.queueDownload(ofBook: "b")

        try database.queueDownload(ofBook: "a")

        #expect(try database.downloadQueue() == ["b", "a"])
    }

    @Test("A Download's files are keyed by relPath; known files keep their state when the tracks are set again")
    func files() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        try database.setDownloadFiles([track("01.mp3", size: 10), track("02.mp3", size: 20)], ofBook: "a")
        var first = try #require(try database.downloadFiles(ofBook: "a").first)
        first.isVerified = true
        try database.saveDownloadFile(first)

        try database.setDownloadFiles([track("01.mp3", size: 10), track("02.mp3", size: 20)], ofBook: "a")

        let files = try database.downloadFiles(ofBook: "a")
        #expect(files.map(\.relPath) == ["01.mp3", "02.mp3"])
        #expect(files.map(\.isVerified) == [true, false])
        #expect(try database.downloadStatus(ofBook: "a")?.totalBytes == 30)
    }

    @Test("A Download's received bytes count verified files whole and the others as far as they got")
    func receivedBytes() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        try database.setDownloadFiles([track("01.mp3", size: 10), track("02.mp3", size: 20)], ofBook: "a")
        var files = try database.downloadFiles(ofBook: "a")
        files[0].isVerified = true
        files[1].receivedBytes = 5
        for file in files { try database.saveDownloadFile(file) }

        let status = try #require(try database.downloadStatus(ofBook: "a"))

        #expect(status.receivedBytes == 15)
        #expect(status.fractionDone == 0.5)
    }

    @Test("Removing a Download deletes it and its files from the Store")
    func remove() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        try database.setDownloadFiles([track("01.mp3", size: 10)], ofBook: "a")

        try database.removeDownload(ofBook: "a")

        #expect(try database.downloadStatus(ofBook: "a") == nil)
        #expect(try database.downloadFiles(ofBook: "a").isEmpty)
        #expect(try database.downloadQueue().isEmpty)
    }

    @Test("The Downloaded list: the queue in FIFO order, then downloaded Books with sizes and the total")
    func list() throws {
        let database = try open(books: ["a", "b", "c", "d"])
        for id in ["c", "a", "b", "d"] { try database.queueDownload(ofBook: id) }
        for id in ["c", "a"] {
            _ = try database.startNextDownload()
            try database.setDownloadFiles([track("01.mp3", size: id == "c" ? 100 : 50)], ofBook: id)
            try database.finishDownload(ofBook: id, at: now)
        }
        try database.saveProgress(BookProgress(bookID: "a", position: 5, lastChanged: now, isFinished: false))

        let list = try database.downloadsList()

        #expect(list.queue.map(\.id) == ["b", "d"])
        #expect(list.downloaded.map(\.id) == ["a", "c"])  // most recently listened first
        #expect(list.downloaded.map(\.title) == ["A", "C"])
        #expect(list.downloaded.map(\.totalBytes) == [50, 100])
        #expect(list.totalBytes == 150)
        #expect(list.activeCount == 2)
    }
}
