import Domain
import Foundation
import Playback
import Store
import Testing
import UI

@Suite("Skip settings")
@MainActor
struct SkipSettingsModelTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
    }

    func player() throws -> Player {
        Player(
            database: database, files: try DownloadFiles(directory: directory.appending(path: "Downloads")),
            audio: FakeAudioPlayer(), clock: TestClock(now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test("Settings show Skip back 15 s and Skip forward 30 s until changed, offering 10, 15, 30 and 60 s")
    func defaults() {
        let settings = SettingsModel(database: database, downloader: nil)

        #expect(settings.skipBack == .fifteen)
        #expect(settings.skipForward == .thirty)
        #expect(SettingsModel.skipChoices == [.ten, .fifteen, .thirty, .sixty])
    }

    @Test("Changing a skip in Settings changes what the player's skip buttons do, and is kept")
    func changesPlayer() throws {
        let player = try player()
        let settings = SettingsModel(database: database, downloader: nil)
        settings.player = player

        settings.setSkipBack(.ten)
        settings.setSkipForward(.sixty)

        #expect(settings.skipBack == .ten)
        #expect(player.skipBackInterval == .ten)
        #expect(player.skipForwardInterval == .sixty)
        let reopened = SettingsModel(database: database, downloader: nil)
        #expect(reopened.skipBack == .ten)
        #expect(reopened.skipForward == .sixty)
    }

    @Test("Without a player the skips are still saved")
    func savesWithoutPlayer() throws {
        let settings = SettingsModel(database: database, downloader: nil)

        settings.setSkipForward(.fifteen)

        #expect(try database.playbackSettings().skipForward == .fifteen)
        #expect(try player().skipForwardInterval == .fifteen)
    }
}
