import Domain
import Foundation
import Store
import Testing

@Suite("Speed and skip settings in the Store")
struct PlaybackSettingsStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }

    func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase.open(at: url)
    }

    @Test("Until set, the speed is 1x and the skips are 15 s back and 30 s forward")
    func defaults() throws {
        #expect(try open().playbackSettings() == PlaybackSettings(speed: 1, skipBack: .fifteen, skipForward: .thirty))
    }

    @Test("Speed, Skip back and Skip forward are kept separately, and survive reopening the database")
    func persists() throws {
        let database = try open()
        try database.setPlaybackSpeed(1.75)
        try database.setSkipBack(.sixty)
        try database.setSkipForward(.ten)
        try database.setSkipBack(.thirty)

        let reopened = try AppDatabase.open(at: url)

        #expect(
            try reopened.playbackSettings() == PlaybackSettings(speed: 1.75, skipBack: .thirty, skipForward: .ten))
    }

    @Test("A speed is stored as the nearest 0.05 step within 0.5x to 3x")
    func speedNormalized() throws {
        let database = try open()
        try database.setPlaybackSpeed(1.33)
        #expect(try database.playbackSettings().speed == 1.35)
        try database.setPlaybackSpeed(5)
        #expect(try database.playbackSettings().speed == 3)
    }

    @Test("The settings are observed")
    func updates() async throws {
        let database = try open()
        var updates = database.playbackSettingsUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.speed == 1)

        try database.setPlaybackSpeed(2)

        #expect(try await updates.next()?.speed == 2)
    }
}
