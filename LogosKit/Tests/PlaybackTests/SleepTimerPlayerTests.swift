import Domain
import Foundation
import Playback
import Testing

@Suite("The player's Sleep Timer")
@MainActor
struct SleepTimerPlayerTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    /// A playing Book with 10-minute Chapters, at `position`.
    func playing(at position: Double = 900, _ id: String = "first") async throws -> Player {
        try fixture.addBook(id, duration: 3600, chapters: PlayerFixture.chapters(3600, every: 600))
        try fixture.saveProgress(id, position: position, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.play(bookID: id)
        return player
    }

    @Test("\"End of this Chapter\" stops hard at the Chapter's end and saves the start of the next Chapter")
    func hardStop() async throws {
        let player = try await playing(at: 900)

        player.setSleepTimer(chapters: 1)
        #expect(player.sleepTimer?.stopAt == 1200)
        fixture.audio.advance(to: 1199.5)
        #expect(player.state == .playing)
        fixture.audio.advance(to: 1200.2)
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
        #expect(player.position == 1200)
        #expect(fixture.audio.currentTime == 1200)
        #expect(try fixture.progress("first")?.position == 1200)
        #expect(player.sleepTimer == nil)
    }

    @Test("The engine reports a Sleep Timer stop as its own stop reason, after saving")
    func reportsStopReason() async throws {
        let player = try await playing(at: 900)
        var stops = player.stops().makeAsyncIterator()
        player.setSleepTimer(chapters: 1)

        fixture.audio.advance(to: 1200.1)

        let stop = await stops.next()
        #expect(stop == PlaybackStop(bookID: "first", position: 1200, reason: .sleepTimer))
    }

    @Test("Pausing and resuming keeps the Sleep Timer, and it still stops at its Chapter's end")
    func survivesPause() async throws {
        let player = try await playing(at: 900)
        player.setSleepTimer(chapters: 2)

        fixture.audio.advance(to: 1000)
        player.pause()
        player.play()
        fixture.audio.advance(to: 1799)
        #expect(player.state == .playing)
        fixture.audio.advance(to: 1800.3)
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(try fixture.progress("first")?.position == 1800)
    }

    @Test("Switching Books clears the Sleep Timer, so it never stops the new Book")
    func switchingBooksClears() async throws {
        let player = try await playing(at: 900)
        try fixture.addBook("second", duration: 3600, chapters: PlayerFixture.chapters(3600, every: 600))
        player.setSleepTimer(chapters: 1)
        let observers = fixture.audio.observerCount

        await player.play(bookID: "second")
        fixture.audio.advance(to: 1200.5)

        #expect(player.sleepTimer == nil)
        #expect(fixture.audio.observerCount == observers - 1)
        #expect(player.state == .playing)
    }

    @Test("Re-picking replaces the Sleep Timer; Cancel clears it")
    func adjust() async throws {
        let player = try await playing(at: 900)

        player.setSleepTimer(chapters: 1)
        player.setSleepTimer(chapters: 3)
        #expect(player.sleepTimer?.stopAt == 2400)
        fixture.audio.advance(to: 1200.5)
        #expect(player.state == .playing)

        player.cancelSleepTimer()
        fixture.audio.advance(to: 2400.5)
        #expect(player.state == .playing)
        #expect(player.sleepTimer == nil)
    }

    @Test("A Sleep Timer in the last Chapter stops at the end of the Book, saved at the end")
    func lastChapter() async throws {
        let player = try await playing(at: 3300)
        var stops = player.stops().makeAsyncIterator()
        player.setSleepTimer(chapters: 1)
        #expect(player.sleepTimer?.endsBook == true)

        fixture.audio.playToEnd(at: 3600)

        #expect(player.state == .paused)
        #expect(player.sleepTimer == nil)
        #expect(try fixture.progress("first")?.position == 3600)
        #expect(await stops.next()?.reason == .endOfBook)
    }

    @Test("A Book with no Chapters is one Chapter: \"End of this Chapter\" is the end of the Book")
    func noChapters() async throws {
        try fixture.addBook("plain", duration: 1200, chapters: [])
        let player = fixture.player()
        await player.play(bookID: "plain")

        player.setSleepTimer(chapters: 1)
        #expect(player.sleepTimer?.stopAt == 1200)
    }

    @Test("Seeking past the stop point clears the Sleep Timer; seeking back before it keeps it")
    func seekPast() async throws {
        let player = try await playing(at: 900)
        player.setSleepTimer(chapters: 1)

        player.seek(to: 300)
        await fixture.settle()
        #expect(player.sleepTimer?.stopAt == 1200)

        player.skip(by: 1000)
        await fixture.settle()
        #expect(player.sleepTimer == nil)
    }
}
