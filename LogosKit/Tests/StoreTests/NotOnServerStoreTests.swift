import Domain
import Foundation
import Store
import Testing

@Suite("Not on Server in the Store")
struct NotOnServerStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open(books: [String] = ["a", "b", "c"]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(books.map { listedBook($0.uppercased(), id: $0) }, syncedAt: now)
        return database
    }

    func data(_ id: String, updatedAt: Int64 = 1_700_000_000_000) -> BookData {
        BookData(
            book: listedBook(id.uppercased(), id: id, updatedAt: updatedAt),
            chapters: [Chapter(id: 0, start: 0, end: 3600.5, title: "One")],
            tracks: [
                AudioTrack(
                    index: 1, ino: "ino-\(id)", relPath: "01.mp3", size: 10, duration: 3600.5, startOffset: 0,
                    mimeType: "audio/mpeg")
            ],
            series: [SeriesMembership(seriesID: "saga", name: "Saga", sequence: "1")])
    }

    func download(_ id: String, in database: AppDatabase) throws {
        try database.queueDownload(ofBook: id)
        _ = try database.startNextDownload()
        try database.setDownloadFiles(data(id).tracks, ofBook: id)
        try database.finishDownload(ofBook: id, at: now)
    }

    @Test("A downloaded Book the Server stops listing is kept, marked Not on Server, with its data")
    func keepsDownloaded() throws {
        let database = try open()
        try database.applyBookData([data("a")])
        try download("a", in: database)

        let applied = try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)

        #expect(applied.removedBookIDs == ["c"])
        #expect(try database.bookIDs() == ["a", "b"])
        let detail = try #require(try database.bookDetail(id: "a"))
        #expect(detail.isNotOnServer)
        #expect(detail.chapters.chapters.map(\.title) == ["One"])
        #expect(detail.series.map(\.name) == ["Saga"])
        #expect(try database.downloadStatus(ofBook: "a")?.state == .downloaded)
        #expect(try database.bookDetail(id: "b")?.isNotOnServer == false)
    }

    @Test("A Book whose Download isn't finished is deleted with its Download when the Server stops listing it")
    func deletesUnfinished() throws {
        let database = try open()
        try database.queueDownload(ofBook: "a")
        try database.queueDownload(ofBook: "b")
        _ = try database.startNextDownload()

        let applied = try database.applyLibraryList([listedBook("C", id: "c")], syncedAt: now)

        #expect(applied.removedBookIDs == ["a", "b"])
        #expect(try database.bookIDs() == ["c"])
        #expect(try database.downloadStatuses().isEmpty)
    }

    @Test("The marker clears when the Server lists the same id again")
    func clearsWhenBack() throws {
        let database = try open()
        try download("a", in: database)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)

        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: now)

        #expect(try database.bookDetail(id: "a")?.isNotOnServer == false)
        #expect(try database.libraryRows().allSatisfy { !$0.isNotOnServer })
    }

    @Test("A Not on Server Book's data and cover are frozen: no later stage fetches them")
    func frozen() throws {
        let database = try open()
        try download("a", in: database)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)
        // The Book's versions are behind (as if it was never fetched), but it isn't fetched again.

        #expect(try !database.booksBehindOnFullData().contains("a"))
        #expect(try !database.coversBehind().map(\.bookID).contains("a"))
    }

    @Test("Library rows and the Downloaded list say which Books are Not on Server")
    func marked() throws {
        let database = try open()
        try download("a", in: database)
        try download("b", in: database)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)

        #expect(try database.libraryRows().filter(\.isNotOnServer).map(\.id) == ["a"])
        #expect(
            try database.downloadsList().downloaded.sorted { $0.id < $1.id }.map(\.isNotOnServer) == [true, false])
    }
}
