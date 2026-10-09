import Domain
import Foundation
import Playback
import Testing

@Suite("Listening sessions from the player")
@MainActor
struct ListeningSessionPlayerTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    /// A Book with 10-minute Chapters, saved at `position`.
    func book(_ id: String = "first", at position: Double = 900) throws {
        try fixture.addBook(id, duration: 3600, chapters: PlayerFixture.chapters(3600, every: 600))
        try fixture.saveProgress(id, position: position, at: fixture.clock.now.addingTimeInterval(-60))
    }

    /// Plays on for `seconds` of real time, the audio moving `rate` times as far.
    func listen(for seconds: Int, rate: Double = 1) async {
        for _ in 0..<seconds {
            fixture.audio.advance(by: rate)
            await fixture.advance(by: .seconds(1))
        }
    }

    var now: Date { Date(millisecondsSince1970: fixture.clock.now.millisecondsSince1970) }

    func sessions() throws -> [ListeningSession] {
        try fixture.database.listeningSessions()
    }

    @Test("Play starts a session where the Book was; each second adds real time, whatever the speed")
    func recordsRealTime() async throws {
        try book()
        let player = fixture.player()
        player.setSpeed(2)
        let pressedPlay = now
        await player.play(bookID: "first")

        await listen(for: 3, rate: 2)
        player.pause()

        let session = try #require(try sessions().first)
        #expect(try sessions().count == 1)
        #expect(session.startTime == 900)
        #expect(session.currentTime == 906)
        #expect(session.timeListening == 3)
        #expect(session.startedAt == pressedPlay)
        #expect(session.updatedAt == now)
        #expect(session.updatedAt == (try fixture.progress("first"))?.lastChanged)
        #expect(session.isOpen)
    }

    @Test("A pause under 10 minutes keeps the session; playing after a longer one starts another")
    func pauses() async throws {
        try book()
        let player = fixture.player()
        await player.play(bookID: "first")
        await listen(for: 2)
        player.pause()

        await fixture.advance(by: .seconds(9 * 60))
        player.play()
        await listen(for: 2)
        player.pause()
        let first = try #require(try sessions().first)
        #expect(try sessions().count == 1)
        #expect(first.timeListening == 4)

        await fixture.advance(by: .seconds(10 * 60))
        player.play()
        await listen(for: 1)

        #expect(try sessions().map(\.id).first == first.id)
        #expect(try sessions().map(\.isOpen) == [false, true])
        #expect(try sessions().last?.startTime == 904)
    }

    @Test("A Sleep Timer stop ends the session at the next Chapter's start")
    func sleepTimerEnds() async throws {
        try book()
        let player = fixture.player()
        await player.play(bookID: "first")
        player.setSleepTimer(chapters: 1)

        fixture.audio.advance(to: 1200.1)
        await fixture.settle()

        let session = try #require(try sessions().first)
        #expect(!session.isOpen)
        #expect(session.currentTime == 1200)
    }

    @Test("Playing another Book ends the first Book's session, whether it was playing or paused")
    func bookSwitchEnds() async throws {
        try book("first")
        try book("second", at: 0)
        try book("third", at: 0)
        let player = fixture.player()
        await player.play(bookID: "first")
        await listen(for: 2)

        await player.play(bookID: "second")
        await listen(for: 2)
        player.pause()
        await player.play(bookID: "third")
        await listen(for: 1)

        #expect(try sessions().map(\.bookID) == ["first", "second", "third"])
        #expect(try sessions().map(\.isOpen) == [false, false, true])
    }

    @Test("Playing to the end of the Book ends the session")
    func endOfBookEnds() async throws {
        try book(at: 3590)
        let player = fixture.player()
        await player.play(bookID: "first")

        fixture.audio.playToEnd(at: 3600)
        await fixture.settle()

        #expect(try sessions().map(\.isOpen) == [false])
        #expect(try sessions().first?.currentTime == 3600)
    }

    @Test("A seek while paused moves the open session's position without adding listening time")
    func seekWhilePaused() async throws {
        try book()
        let player = fixture.player()
        await player.play(bookID: "first")
        await listen(for: 2)
        player.pause()
        await fixture.advance(by: .seconds(30))

        player.seek(to: 1500)

        let session = try #require(try sessions().first)
        #expect(session.currentTime == 1500)
        #expect(session.timeListening == 2)
        #expect(session.updatedAt == now)
    }

    @Test("An interruption that resumes keeps the same session; the time it lasted isn't counted")
    func interruptionContinues() async throws {
        try book()
        let player = fixture.player()
        await player.play(bookID: "first")
        await listen(for: 2)

        fixture.session.send(.interrupted)
        await fixture.advance(by: .seconds(60))
        fixture.session.send(.interruptionEnded(shouldResume: true))
        await listen(for: 2)
        player.pause()

        #expect(try sessions().count == 1)
        #expect(try sessions().first?.timeListening == 4)
        #expect(try sessions().first?.isOpen == true)
    }

    @Test("Restoring the last-played Book at launch starts no session")
    func restoreStartsNothing() async throws {
        try book()
        let player = fixture.player()

        await player.restoreLastPlayed()

        #expect(try sessions().isEmpty)
    }
}
