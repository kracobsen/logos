import Domain
import Foundation
import Store
import Testing

@Suite("The last-played Book in the Store")
struct PlaybackStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(["a", "b", "c"].map { listedBook($0.uppercased(), id: $0) }, syncedAt: now)
        return database
    }

    func download(_ bookID: String, in database: AppDatabase) throws {
        try database.queueDownload(ofBook: bookID)
        _ = try database.startNextDownload()
        try database.finishDownload(ofBook: bookID, at: now)
    }

    func save(_ bookID: String, minutesAgo: Double, in database: AppDatabase, finished: Bool = false) throws {
        try database.saveProgress(
            BookProgress(
                bookID: bookID, position: 10, lastChanged: now.addingTimeInterval(-minutesAgo * 60),
                isFinished: finished))
    }

    @Test("The last-played Book is the most recently changed downloaded one")
    func mostRecentDownloaded() throws {
        let database = try open()
        try download("a", in: database)
        try download("b", in: database)
        try save("a", minutesAgo: 30, in: database)
        try save("b", minutesAgo: 10, in: database)
        try save("c", minutesAgo: 1, in: database)  // newer, but not downloaded

        #expect(try database.lastPlayedBookID() == "b")
    }

    @Test("Nothing is last-played without progress on a downloaded Book")
    func none() throws {
        let database = try open()
        try download("a", in: database)
        try save("c", minutesAgo: 1, in: database)

        #expect(try database.lastPlayedBookID() == nil)
    }
}
