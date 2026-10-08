import Domain
import Foundation
import Playback
import Testing

@Suite("Picked up from another device")
@MainActor
struct PickUpTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    /// A paused player on `id` at `position` (saved a minute ago), following fetches.
    private func pausedPlayer(_ id: String = "book", at position: Double = 100) async throws -> (
        Player, Task<Void, Never>
    ) {
        try fixture.addBook(id)
        try fixture.saveProgress(id, position: position, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.restoreLastPlayed()
        let following = Task { await player.observePickUps() }
        await fixture.settle()
        return (player, following)
    }

    /// Applies a fetch for `id`, `secondsAgo` before now on the test clock.
    private func fetch(
        _ id: String = "book", position: Double, isFinished: Bool = false, secondsAgo: Double = 10
    ) async throws {
        let lastUpdate = fixture.clock.now.addingTimeInterval(-secondsAgo).millisecondsSince1970
        try fixture.database.applyFetchedProgress([
            FetchedProgress(bookID: id, position: position, isFinished: isFinished, lastUpdate: lastUpdate)
        ])
        await fixture.settle()
    }

    @Test("A newer position for the paused Book moves the player there, with a notice and without a local save")
    func movesPausedBook() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }

        try await fetch(position: 1500, secondsAgo: 10)

        #expect(player.state == .paused)
        #expect(player.position == 1500)
        #expect(fixture.audio.currentTime == 1500)
        #expect(!fixture.audio.isPlaying)
        #expect(player.pickedUp == Player.PickedUp(position: 1500, isFinished: false))
        let stored = try fixture.progress("book")
        #expect(stored?.position == 1500)
        #expect(stored?.lastChanged == fixture.clock.now.addingTimeInterval(-10))
    }

    @Test("Undo is a local seek back: it's saved as newer, so the same fetch doesn't win again")
    func undo() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }
        try await fetch(position: 1500, secondsAgo: 10)
        await fixture.advance(by: .seconds(5))

        player.undoPickUp()
        await fixture.settle()

        #expect(player.pickedUp == nil)
        #expect(player.position == 100)
        #expect(fixture.audio.currentTime == 100)
        #expect(
            try fixture.progress("book")
                == BookProgress(bookID: "book", position: 100, lastChanged: fixture.clock.now, isFinished: false))

        try await fetch(position: 1500, secondsAgo: 15)

        #expect(player.position == 100)
        #expect(player.pickedUp == nil)
    }

    @Test("Finished set on another device is picked up too, and Undo clears it again")
    func finished() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }

        try await fetch(position: 3600, isFinished: true)

        #expect(player.isFinished)
        #expect(player.position == 3600)
        #expect(player.pickedUp == Player.PickedUp(position: 3600, isFinished: true))

        player.undoPickUp()
        await fixture.settle()

        #expect(!player.isFinished)
        #expect(player.position == 100)
        #expect(try fixture.progress("book")?.isFinished == false)
    }

    @Test("A playing Book is never moved, and its own position is saved straight back")
    func playingBookIsNotMoved() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }
        player.play()
        fixture.audio.advance(to: 200)
        await fixture.advance(by: .seconds(1))

        // Newer than the player's last save: the other device acted half a second ago.
        try await fetch(position: 1500, secondsAgo: 0.5)

        #expect(player.state == .playing)
        #expect(fixture.audio.isPlaying)
        #expect(player.position == 200)
        #expect(fixture.audio.currentTime == 200)
        #expect(player.pickedUp == nil)
        #expect(
            try fixture.progress("book")
                == BookProgress(bookID: "book", position: 200, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("No notice when the Server's position is within about 2 s and Finished is unchanged")
    func noFalseNotice() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }

        try await fetch(position: 101.5)
        try await fetch(position: 98, secondsAgo: 5)

        #expect(player.pickedUp == nil)
        #expect(player.position == 100)
        #expect(fixture.audio.seeks.count == 1)  // only restoring the saved position
    }

    @Test("A fetch for another Book leaves the loaded one alone")
    func otherBook() async throws {
        let (player, following) = try await pausedPlayer("book", at: 100)
        defer { following.cancel() }
        try fixture.addBook("other")

        try await fetch("other", position: 900)

        #expect(player.position == 100)
        #expect(player.pickedUp == nil)
    }

    @Test("Playing, seeking or dismissing removes the notice and keeps the new position")
    func noticeGoesAway() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }

        try await fetch(position: 1500)
        #expect(player.pickedUp?.position == 1500)
        player.skip(by: 30)
        #expect(player.pickedUp == nil)
        #expect(player.position == 1530)

        try await fetch(position: 2000, secondsAgo: -10)
        player.dismissPickUp()
        #expect(player.pickedUp == nil)
        #expect(player.position == 2000)

        try await fetch(position: 3000, secondsAgo: -20)
        player.play()
        #expect(player.pickedUp == nil)
        #expect(player.position == 3000)
    }

    @Test("A paused Book with listening not yet sent isn't picked up")
    func unsentListeningIsKept() async throws {
        let (player, following) = try await pausedPlayer(at: 100)
        defer { following.cancel() }
        player.play()
        fixture.audio.advance(to: 160)
        await fixture.advance(by: .seconds(1))
        player.pause()

        try await fetch(position: 1500, secondsAgo: -10)

        #expect(player.position == 160)
        #expect(player.pickedUp == nil)
    }
}
