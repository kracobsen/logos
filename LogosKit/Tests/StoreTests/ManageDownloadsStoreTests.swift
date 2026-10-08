import Domain
import Foundation
import Store
import Testing

@Suite("Managing Downloads in the Store")
struct ManageDownloadsStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open(books: [String] = ["a", "b", "c", "d"]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(books.map { listedBook($0.uppercased(), id: $0) }, syncedAt: now)
        return database
    }

    func track(_ relPath: String, size: Int64) -> AudioTrack {
        AudioTrack(
            index: 1, ino: "ino-\(relPath)", relPath: relPath, size: size, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg")
    }

    func download(_ id: String, size: Int64 = 10, in database: AppDatabase) throws {
        try database.queueDownload(ofBook: id)
        #expect(try database.startNextDownload() == id)
        try database.setDownloadFiles([track("01.mp3", size: size)], ofBook: id)
        try database.finishDownload(ofBook: id, at: now)
    }

    @Test("Reordering moves queued Books; the downloading one stays where it is")
    func reorder() throws {
        let database = try open()
        for id in ["a", "b", "c", "d"] { try database.queueDownload(ofBook: id) }
        _ = try database.startNextDownload()

        try database.reorderQueuedDownloads(["d", "b", "c"])

        #expect(try database.downloadQueue() == ["a", "d", "b", "c"])
        #expect(try database.downloadsList().queue.map(\.id) == ["a", "d", "b", "c"])
        try database.finishDownload(ofBook: "a")
        #expect(try database.startNextDownload() == "d")
    }

    @Test("Reordering ignores Books that aren't queued and keeps queued ones it wasn't given in place")
    func reorderPartial() throws {
        let database = try open()
        for id in ["a", "b", "c"] { try database.queueDownload(ofBook: id) }

        try database.reorderQueuedDownloads(["c", "x", "a"])

        #expect(try database.downloadQueue() == ["c", "b", "a"])
    }

    @Test("Removing a Download keeps the Book and its progress")
    func removeKeepsBook() throws {
        let database = try open()
        try download("a", in: database)
        try database.saveProgress(BookProgress(bookID: "a", position: 5, lastChanged: now, isFinished: false))

        let deletedBook = try database.discardDownload(ofBook: "a")

        #expect(!deletedBook)
        #expect(try database.downloadStatus(ofBook: "a") == nil)
        #expect(try database.downloadFiles(ofBook: "a").isEmpty)
        #expect(try database.bookIDs().contains("a"))
        #expect(try database.progress(ofBook: "a")?.position == 5)
    }

    @Test("Removing the Download of a Not on Server Book deletes the Book entirely")
    func removeNotOnServer() throws {
        let database = try open()
        try download("a", in: database)
        try database.saveProgress(BookProgress(bookID: "a", position: 5, lastChanged: now, isFinished: false))
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)

        let deletedBook = try database.discardDownload(ofBook: "a")

        #expect(deletedBook)
        #expect(try database.bookIDs() == ["b"])
        #expect(try database.progress(ofBook: "a") == nil)
        #expect(try database.bookDetail(id: "a") == nil)
    }

    @Test("Largest first sorts downloaded Books by size; recently listened stays the default")
    func largestFirst() throws {
        let database = try open()
        try download("a", size: 10, in: database)
        try download("b", size: 30, in: database)
        try download("c", size: 20, in: database)
        try database.saveProgress(BookProgress(bookID: "a", position: 5, lastChanged: now, isFinished: false))

        let list = try database.downloadsList()

        #expect(list.downloaded.map(\.id) == ["a", "b", "c"])
        #expect(list.downloaded(in: .recentlyListened).map(\.id) == ["a", "b", "c"])
        #expect(list.downloaded(in: .largestFirst).map(\.id) == ["b", "c", "a"])
    }
}
