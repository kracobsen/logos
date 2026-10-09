import Domain
import Foundation
import Testing

@testable import Store

@Suite("Progress picked up from the Server")
struct FetchedProgressUpdatesTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test("Each applied fetch reports the progress it adopted, and only real changes")
    func reportsAdoptedProgress() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(["moved", "same", "older"].map { listedBook($0) }, syncedAt: now)
        let local = now.millisecondsSince1970
        for id in ["moved", "same", "older"] {
            try database.saveProgress(BookProgress(bookID: id, position: 100, lastChanged: now, isFinished: false))
        }
        var updates = database.fetchedProgressUpdates().makeAsyncIterator()

        try database.applyFetchedProgress([
            FetchedProgress(bookID: "moved", position: 500, isFinished: false, lastUpdate: local + 1000),
            FetchedProgress(bookID: "same", position: 101.5, isFinished: false, lastUpdate: local + 1000),
            FetchedProgress(bookID: "older", position: 900, isFinished: false, lastUpdate: local - 1000),
        ])
        try database.applyFetchedProgress([
            FetchedProgress(bookID: "same", position: 100, isFinished: true, lastUpdate: local + 2000)
        ])

        #expect(
            await updates.next() == [
                BookProgress(
                    bookID: "moved", position: 500, lastChanged: now.addingTimeInterval(1), isFinished: false)
            ])
        #expect(
            await updates.next() == [
                BookProgress(bookID: "same", position: 100, lastChanged: now.addingTimeInterval(2), isFinished: true)
            ])
    }

    @Test("A fetch that changes nothing reports nothing")
    func quietWhenNothingChanged() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList([listedBook("a")], syncedAt: now)
        try database.saveProgress(BookProgress(bookID: "a", position: 100, lastChanged: now, isFinished: false))
        var updates = database.fetchedProgressUpdates().makeAsyncIterator()

        try database.applyFetchedProgress([
            FetchedProgress(bookID: "a", position: 102, isFinished: false, lastUpdate: now.millisecondsSince1970 + 1)
        ])
        try database.applyFetchedProgress([
            FetchedProgress(bookID: "a", position: 300, isFinished: false, lastUpdate: now.millisecondsSince1970 + 5)
        ])

        #expect(await updates.next()?.map(\.position) == [300])
    }
}
