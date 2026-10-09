import Domain
import Foundation
import Store
import Testing

@Suite("Finished changes in the outbox")
struct FinishedChangeStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func open(books: [String] = ["a", "b"]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(books.map { listedBook($0.uppercased(), id: $0) }, syncedAt: start)
        return database
    }

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// A Player position write `seconds` after the start.
    func write(
        _ database: AppDatabase, _ bookID: String = "a", at seconds: TimeInterval, position: Double,
        playing: Bool = false, finished: Bool = false
    ) throws {
        try database.saveProgress(
            BookProgress(bookID: bookID, position: position, lastChanged: at(seconds), isFinished: finished),
            listening: playing)
    }

    func download(_ id: String, in database: AppDatabase) throws {
        let track = AudioTrack(
            index: 1, ino: "ino-\(id)", relPath: "01.mp3", size: 10, duration: 3600.5, startOffset: 0,
            mimeType: "audio/mpeg")
        try database.queueDownload(ofBook: id)
        _ = try database.startNextDownload()
        try database.setDownloadFiles([track], ofBook: id)
        try database.finishDownload(ofBook: id, at: start)
    }

    @Test("The Player finishing a Book queues a Finished change with the position and when the listener acted")
    func playerFinishQueues() throws {
        let database = try open()
        try write(database, at: 0, position: 3580, playing: true)
        #expect(try database.pendingFinishedChanges().isEmpty)

        try write(database, at: 5, position: 3600.5, finished: true)

        #expect(
            try database.pendingFinishedChanges()
                == [
                    PendingFinishedChange(
                        change: FinishedChange(bookID: "a", isFinished: true, position: 3600.5, lastUpdate: at(5)),
                        duration: 3600.5)
                ])
    }

    @Test("Play on a Finished Book clears Finished: that queues a change too, replacing the earlier one")
    func clearingReplaces() throws {
        let database = try open()
        try write(database, at: 0, position: 3600.5, finished: true)
        try write(database, at: 10, position: 0)
        try write(database, at: 10, position: 0, playing: true)
        try write(database, at: 11, position: 1, playing: true)

        #expect(
            try database.pendingFinishedChanges().map(\.change)
                == [FinishedChange(bookID: "a", isFinished: false, position: 0, lastUpdate: at(10))])
    }

    @Test("Finished set or cleared by hand queues a change; setting what's already there doesn't")
    func byHand() throws {
        let database = try open()
        try database.setFinished(false, ofBook: "a", at: at(1))
        #expect(try database.pendingFinishedChanges().isEmpty)

        try database.setFinished(true, ofBook: "a", at: at(2))
        try database.setFinished(true, ofBook: "b", at: at(3))

        #expect(
            try database.pendingFinishedChanges().map(\.change)
                == [
                    FinishedChange(bookID: "a", isFinished: true, position: 3600.5, lastUpdate: at(2)),
                    FinishedChange(bookID: "b", isFinished: true, position: 3600.5, lastUpdate: at(3)),
                ])
    }

    @Test("A fetch never overwrites a Book with a pending Finished change")
    func protectsFromFetch() throws {
        let database = try open()
        try database.setFinished(true, ofBook: "a", at: at(2))
        let newer = FetchedProgress(
            bookID: "a", position: 900, isFinished: false, lastUpdate: at(60).millisecondsSince1970)

        #expect(try database.applyFetchedProgress([newer]).changedBookIDs.isEmpty)
        #expect(try database.progress(ofBook: "a")?.isFinished == true)
    }

    @Test("Confirming a change removes it, but not a newer one made since")
    func confirm() throws {
        let database = try open()
        try database.setFinished(true, ofBook: "a", at: at(2))
        let sent = try #require(try database.pendingFinishedChanges().first?.change)
        try database.setFinished(false, ofBook: "a", at: at(3))

        try database.confirmFinishedChange(sent)
        #expect(try database.pendingFinishedChanges().map(\.change.isFinished) == [false])

        try database.confirmFinishedChange(try #require(try database.pendingFinishedChanges().first?.change))
        #expect(try database.pendingFinishedChanges().isEmpty)
    }

    @Test("Overruled changes are dropped, so the fetched Server state then applies")
    func dropOverruled() throws {
        let database = try open()
        try database.setFinished(true, ofBook: "a", at: at(2))
        try database.setFinished(true, ofBook: "b", at: at(2))
        let server = [
            FetchedProgress(bookID: "a", position: 900, isFinished: false, lastUpdate: at(60).millisecondsSince1970),
            FetchedProgress(bookID: "b", position: 900, isFinished: false, lastUpdate: at(1).millisecondsSince1970),
        ]

        #expect(try database.dropFinishedChanges(overruledBy: server) == ["a"])

        #expect(try database.pendingFinishedChanges().map(\.change.bookID) == ["b"])
        #expect(try database.applyFetchedProgress(server).changedBookIDs == ["a"])
        #expect(try database.progress(ofBook: "a")?.position == 900)
    }

    @Test("A Not on Server Book's change is held, sent if the id comes back, and deleted with its Download")
    func notOnServer() throws {
        let database = try open()
        try download("a", in: database)
        try database.setFinished(true, ofBook: "a", at: at(2))
        try database.setFinished(true, ofBook: "b", at: at(2))
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: start)
        #expect(try database.pendingFinishedChanges().map(\.change.bookID) == ["b"])

        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: start)
        #expect(try database.pendingFinishedChanges().map(\.change.bookID) == ["a", "b"])

        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: start)
        #expect(try database.discardDownload(ofBook: "a"))
        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: start)
        #expect(try database.pendingFinishedChanges().map(\.change.bookID) == ["b"])
    }

    @Test("Pending changes are observed")
    func observed() async throws {
        let database = try open()
        var updates = database.pendingFinishedChangeUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.isEmpty == true)

        try database.setFinished(true, ofBook: "a", at: at(2))

        #expect(try await updates.next()?.map(\.bookID) == ["a"])
    }
}
