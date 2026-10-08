import Domain
import Foundation
import Playback
import Testing

/// A reload (the decode-failure workaround, or rebuilding after a media-services reset) swaps the player's timeline,
/// which sits at 0 until the reload's seek lands.
@Suite("The player engine while a reload is in flight")
@MainActor
struct PlayerReloadTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    @Test("A decode retry whose load is slow saves nothing until it's back at the position")
    func decodeRetryDoesNotSaveZero() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1500)
        await fixture.advance(by: .seconds(1))
        let saved = try fixture.progress("first")
        #expect(saved?.position == 1500)
        fixture.audio.holdsLoads = true

        fixture.audio.failToDecode()
        await fixture.advance(by: .seconds(3))

        #expect(try fixture.progress("first") == saved)
        #expect(player.position == 1499)

        await fixture.audio.finishLoads()
        await fixture.settle()
        #expect(fixture.audio.isPlaying)
        await fixture.advance(by: .seconds(1))
        #expect(try fixture.progress("first")?.position == 1499)
    }

    @Test("Going to the background during a decode retry saves the position it's reloading to")
    func backgroundDuringReload() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1500)
        fixture.audio.holdsLoads = true
        fixture.audio.failToDecode()
        await fixture.settle()

        player.enteredBackground()

        #expect(try fixture.progress("first")?.position == 1499)
        await fixture.audio.finishLoads()
    }

    /// A paused player on "book" at 100 following fetches; `reload` starts a reload that's held, then a newer fetch
    /// at 1500 lands before the reload finishes.
    private func pickUpDuringReload(_ reload: () -> Void) async throws -> Player {
        try fixture.addBook("book")
        try fixture.saveProgress("book", position: 100, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.restoreLastPlayed()
        let following = Task { await player.observePickUps() }
        defer { following.cancel() }
        await fixture.settle()
        fixture.audio.holdsLoads = true

        reload()
        await fixture.settle()
        try fixture.database.applyFetchedProgress([
            FetchedProgress(
                bookID: "book", position: 1500, isFinished: false,
                lastUpdate: fixture.clock.now.addingTimeInterval(-10).millisecondsSince1970)
        ])
        await fixture.settle()
        await fixture.audio.finishLoads()
        await fixture.settle()
        return player
    }

    @Test("A pick-up arriving while a reset reload is in flight is applied once the Book is back")
    func pickUpDuringResetReload() async throws {
        let player = try await pickUpDuringReload { fixture.session.send(.mediaServicesReset) }

        #expect(player.state == .paused)
        #expect(player.position == 1500)
        #expect(fixture.audio.currentTime == 1500)
        #expect(player.pickedUp == Player.PickedUp(position: 1500, isFinished: false))
    }

    @Test("A pick-up arriving while a paused Book's decode retry is in flight is applied once it's back")
    func pickUpDuringDecodeReload() async throws {
        let player = try await pickUpDuringReload { fixture.audio.failToDecode() }

        #expect(player.state == .paused)
        #expect(player.position == 1500)
        #expect(fixture.audio.currentTime == 1500)
        #expect(player.pickedUp == Player.PickedUp(position: 1500, isFinished: false))
    }
}
