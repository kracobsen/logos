import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing

@Suite("Library sync: Not on Server")
struct NotOnServerSyncTests {
    let first = FakeServer.book("The First Light", id: "first-light", updatedAt: 1)
    let plain = FakeServer.book("Plain Silence", id: "plain-silence")
    let dawn = [Chapter(id: 0, start: 0, end: 40, title: "Dawn")]
    let track = AudioTrack(
        index: 1, ino: "443", relPath: "01.mp3", size: 10, duration: 40, startOffset: 0, mimeType: "audio/mpeg")

    /// A signed-in Logos that has synced both Books and downloaded The First Light.
    func downloaded() async throws -> SignedInFixture {
        let fixture = try await SignedInFixture(books: [first, plain])
        fixture.server.bookData = [BookData(book: first, chapters: dawn, tracks: [track], series: [])]
        #expect(await fixture.librarySync().sync(.launch) == .synced)
        try fixture.database.queueDownload(ofBook: first.id)
        _ = try fixture.database.startNextDownload()
        try fixture.database.setDownloadFiles([track], ofBook: first.id)
        try fixture.database.finishDownload(ofBook: first.id)
        return fixture
    }

    @Test("A downloaded Book the Server drops stays, Not on Server, with its Chapters; a plain one is deleted")
    func keepsDownloaded() async throws {
        let fixture = try await downloaded()
        try fixture.database.queueDownload(ofBook: plain.id)
        fixture.server.books = [FakeServer.book("Second Dawn", id: "second-dawn")]
        let batchesBefore = fixture.batches.count

        #expect(await fixture.librarySync().sync(.manual) == .synced)

        #expect(try fixture.titles() == ["The First Light", "Second Dawn"])
        let detail = try #require(try fixture.database.bookDetail(id: first.id))
        #expect(detail.isNotOnServer)
        #expect(detail.chapters.chapters == dawn)
        #expect(try fixture.database.downloadStatus(ofBook: first.id)?.state == .downloaded)
        #expect(try fixture.database.downloadStatus(ofBook: plain.id) == nil)
        #expect(fixture.batches.dropFirst(batchesBefore).joined().sorted() == ["second-dawn"])
    }

    @Test("Opening a Not on Server Book whose data was never fetched asks the Server nothing")
    func detailFetchSkipped() async throws {
        let fixture = try await SignedInFixture(books: [first, plain])
        try fixture.database.applyLibraryList([first, plain], syncedAt: fixture.clock.now)
        try fixture.database.queueDownload(ofBook: first.id)
        _ = try fixture.database.startNextDownload()
        try fixture.database.setDownloadFiles([track], ofBook: first.id)
        try fixture.database.finishDownload(ofBook: first.id)
        try fixture.database.applyLibraryList([plain], syncedAt: fixture.clock.now)

        await fixture.librarySync().fetchFullDataNow(ofBook: first.id)

        #expect(fixture.singleFetches.isEmpty)
    }

    @Test("When the same id is listed again the marker clears and its data is fetched if it changed")
    func comesBack() async throws {
        let fixture = try await downloaded()
        fixture.server.books = [plain]
        #expect(await fixture.librarySync().sync(.manual) == .synced)
        let back = FakeServer.book("The First Light (Revised)", id: "first-light", updatedAt: 2)
        let noon = [Chapter(id: 0, start: 0, end: 40, title: "Noon")]
        fixture.server.books = [back, plain]
        fixture.server.bookData = [BookData(book: back, chapters: noon, tracks: [track], series: [])]

        #expect(await fixture.librarySync().sync(.manual) == .synced)

        let detail = try #require(try fixture.database.bookDetail(id: first.id))
        #expect(!detail.isNotOnServer)
        #expect(detail.title == "The First Light (Revised)")
        #expect(detail.chapters.chapters == noon)
        #expect(try fixture.database.downloadStatus(ofBook: first.id)?.state == .downloaded)
    }
}
