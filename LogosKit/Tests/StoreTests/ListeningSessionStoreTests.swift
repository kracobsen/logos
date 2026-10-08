import Domain
import Foundation
import Store
import Testing

@Suite("Listening sessions outbox in the Store")
struct ListeningSessionStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func open(books: [String] = ["a", "b"]) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(books.map { listedBook($0.uppercased(), id: $0) }, syncedAt: start)
        return database
    }

    /// A position write `seconds` after the start.
    func write(
        _ database: AppDatabase, _ bookID: String = "a", at seconds: TimeInterval, position: Double,
        playing: Bool = true, finished: Bool = false
    ) throws {
        try database.saveProgress(
            BookProgress(
                bookID: bookID, position: position, lastChanged: start.addingTimeInterval(seconds),
                isFinished: finished),
            listening: playing)
    }

    func confirmAll(_ database: AppDatabase) throws {
        try database.confirmListeningSessions(database.unsentListeningSessions().map { ($0.session.id, $0.revision) })
    }

    @Test("Listening for 3 s and pausing leaves one unsent session with its totals and the Book's details")
    func records() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101)
        try write(database, at: 2, position: 102)
        try write(database, at: 3, position: 103, playing: false)

        let unsent = try database.unsentListeningSessions()
        let entry = try #require(unsent.first)
        #expect(unsent.count == 1)
        #expect(entry.session.bookID == "a")
        #expect(entry.session.startTime == 100)
        #expect(entry.session.currentTime == 103)
        #expect(entry.session.timeListening == 3)
        #expect(entry.session.startedAt == start)
        #expect(entry.session.updatedAt == start.addingTimeInterval(3))
        #expect(entry.session.isOpen)
        #expect(
            (entry.mediaID, entry.title, entry.authorName, entry.duration) == ("media-a", "A", "Ada Fixture", 3600.5))
        #expect(try database.progress(ofBook: "a")?.position == 103)
    }

    @Test("A confirmed open session stays (it's still being added to) and is unsent again after the next write")
    func confirmedOpenStays() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try confirmAll(database)
        #expect(try database.unsentListeningSessions().isEmpty)
        #expect(try database.listeningSessions().count == 1)

        try write(database, at: 1, position: 101)

        #expect(try database.unsentListeningSessions().map(\.session.currentTime) == [101])
    }

    @Test("Confirming a revision that has since changed doesn't count as delivering the change")
    func confirmsOnlyTheSentRevision() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        let sent = try database.unsentListeningSessions()
        try write(database, at: 1, position: 101, playing: false)
        try database.endListeningSession(ofBook: "a")

        try database.confirmListeningSessions(sent.map { ($0.session.id, $0.revision) })

        let unsent = try database.unsentListeningSessions()
        #expect(unsent.map(\.session.currentTime) == [101])
        try confirmAll(database)
        #expect(try database.listeningSessions().isEmpty)
    }

    @Test("A closed session leaves the outbox only once the Server confirms its latest state")
    func deletesOnlyOnConfirmation() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101, playing: false)
        try database.endListeningSession(ofBook: "a")
        #expect(try database.listeningSessions().map(\.isOpen) == [false])

        try database.confirmListeningSessions([])
        #expect(try database.listeningSessions().count == 1)

        try confirmAll(database)
        #expect(try database.listeningSessions().isEmpty)
    }

    @Test("Sessions left open by a kill are closed at launch with their last saved state")
    func closesLeftOpen() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101)

        try database.closeListeningSessionsLeftOpen()

        let session = try #require(try database.listeningSessions().first)
        #expect(!session.isOpen)
        #expect(!session.isPlaying)
        #expect((session.currentTime, session.timeListening) == (101, 1))
        #expect(try database.unsentListeningSessions().count == 1)
    }

    @Test("A session paused for 10 minutes is closed; a shorter pause isn't")
    func closesPausedTooLong() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101, playing: false)

        try database.closeListeningSessionsPausedTooLong(at: start.addingTimeInterval(1 + 599))
        #expect(try database.listeningSessions().map(\.isOpen) == [true])
        try database.closeListeningSessionsPausedTooLong(at: start.addingTimeInterval(1 + 600))
        #expect(try database.listeningSessions().map(\.isOpen) == [false])
    }

    @Test("Only the playing session counts as listening")
    func isListening() throws {
        let database = try open()
        #expect(try !database.isListening())
        try write(database, at: 0, position: 100)
        #expect(try database.isListening())
        try write(database, at: 1, position: 101, playing: false)
        #expect(try !database.isListening())
    }

    @Test("A fetch never overwrites a Book with unsent entries; once they're confirmed it's compared again")
    func fetchSkipsUnsent() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101, playing: false)
        let newer = FetchedProgress(
            bookID: "a", position: 900, isFinished: false,
            lastUpdate: start.addingTimeInterval(60).millisecondsSince1970)

        #expect(try database.applyFetchedProgress([newer]).changedBookIDs.isEmpty)
        #expect(try database.progress(ofBook: "a")?.position == 101)

        try confirmAll(database)
        #expect(try database.applyFetchedProgress([newer]).changedBookIDs == ["a"])
        #expect(try database.progress(ofBook: "a")?.position == 900)
    }

    @Test("A Not on Server Book's sessions are held, and sent again if the same id comes back")
    func holdsNotOnServer() throws {
        let database = try open()
        try download("a", in: database)
        try write(database, at: 0, position: 100)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: start)
        #expect(try database.unsentListeningSessions().isEmpty)
        #expect(try database.listeningSessions().count == 1)

        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: start)

        #expect(try database.unsentListeningSessions().map(\.session.bookID) == ["a"])
    }

    @Test("Removing a Not on Server Book's Download deletes its held sessions; other Books' are kept")
    func discardDeletesHeld() throws {
        let database = try open()
        try download("a", in: database)
        try write(database, at: 0, position: 100)
        try write(database, "b", at: 1, position: 5)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: start)

        #expect(try database.discardDownload(ofBook: "a"))

        #expect(try database.listeningSessions().map(\.bookID) == ["b"])
    }

    @Test("Marking a Book Finished (or clearing it) by hand ends its open session")
    func finishedByHandEnds() throws {
        let database = try open()
        try write(database, at: 0, position: 100)
        try write(database, at: 1, position: 101, playing: false)

        try database.setFinished(true, ofBook: "a", at: start.addingTimeInterval(5))

        #expect(try database.listeningSessions().map(\.isOpen) == [false])
    }

    @Test("The device id is made once and kept")
    func deviceID() throws {
        let database = try open()
        let id = try database.clientDeviceID()
        #expect(try database.clientDeviceID() == id)
        #expect(UUID(uuidString: id) != nil)
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
}
