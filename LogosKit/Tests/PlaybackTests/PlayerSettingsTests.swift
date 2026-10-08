import Domain
import Foundation
import Playback
import Testing

@Suite("The player's speed and skips")
@MainActor
struct PlayerSettingsTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    @Test("The speed applies to the player at once, is published and is kept for the next launch")
    func speed() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")

        player.setSpeed(1.5)

        #expect(fixture.audio.rate == 1.5)
        #expect(player.speed == 1.5)
        #expect(player.rate == 1.5)
        #expect(fixture.audio.isPlaying)
        #expect(try fixture.database.playbackSettings().speed == 1.5)
    }

    @Test("A speed off the 0.05 grid or outside 0.5x to 3x is set to the nearest one there is")
    func speedNormalized() throws {
        let player = fixture.player()

        player.setSpeed(1.33)
        #expect(player.speed == 1.35)
        #expect(fixture.audio.rate == Float(1.35))

        player.setSpeed(0.2)
        #expect(player.speed == 0.5)
    }

    @Test("At launch the player starts at the saved speed, before any Book plays")
    func speedRestored() async throws {
        try fixture.database.setPlaybackSpeed(2.25)
        try fixture.addBook("first")

        let player = fixture.player()

        #expect(player.speed == 2.25)
        #expect(fixture.audio.rate == Float(2.25))
        await player.play(bookID: "first")
        #expect(fixture.audio.rate == Float(2.25))
    }

    @Test("Playing faster doesn't change Book time: positions are saved as the player reports them")
    func positionsStayInBookTime() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        player.setSpeed(2)
        await player.play(bookID: "first")

        fixture.audio.advance(to: 20)
        player.pause()

        #expect(player.position == 20)
        #expect(try fixture.progress("first")?.position == 20)
    }

    @Test("Skips default to 15 s back and 30 s forward")
    func defaultSkips() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 100, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.play(bookID: "first")
        #expect(player.skipBackInterval == .fifteen)
        #expect(player.skipForwardInterval == .thirty)

        player.skipBack()
        #expect(player.position == 85)
        player.skipForward()
        #expect(player.position == 115)
        #expect(try fixture.progress("first")?.position == 115)
    }

    @Test("Skips use the configured intervals, which are kept for the next launch")
    func configuredSkips() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 100, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.play(bookID: "first")

        player.setSkipBackInterval(.sixty)
        player.setSkipForwardInterval(.ten)
        player.skipBack()
        #expect(player.position == 40)
        player.skipForward()
        #expect(player.position == 50)

        let relaunched = fixture.player()
        #expect(relaunched.skipBackInterval == .sixty)
        #expect(relaunched.skipForwardInterval == .ten)
    }

    @Test("A skip stays within the Book")
    func skipClamped() async throws {
        try fixture.addBook("first", duration: 3600)
        try fixture.saveProgress("first", position: 5, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.play(bookID: "first")

        player.skipBack()
        #expect(player.position == 0)
    }
}
