import Domain
import Foundation
import Playback
import Testing

@Suite("The player and Finished")
@MainActor
struct PlayerFinishedTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    private func finishedAtEnd(_ id: String = "first", duration: Double = 3600) -> BookProgress {
        BookProgress(bookID: id, position: duration, lastChanged: fixture.clock.now, isFinished: true)
    }

    @Test("At the end of the Book playing stops, and the Book is Finished with its position at the end")
    func endOfBook() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3500)
        await fixture.advance(by: .seconds(5))

        fixture.audio.playToEnd(at: 3600)

        #expect(player.state == .paused)
        #expect(player.isFinished)
        #expect(player.position == 3600)
        #expect(try fixture.progress("first") == finishedAtEnd())
        await fixture.advance(by: .seconds(3))
        #expect(!fixture.audio.isPlaying)
        #expect(try fixture.progress("first") == finishedAtEnd().with(lastChanged: fixture.clock.now - 3))
    }

    @Test("Pausing within the last 30 s finishes the Book, at the end")
    func pauseNearEnd() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3575)

        player.pause()
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(player.isFinished)
        #expect(player.position == 3600)
        #expect(fixture.audio.currentTime == 3600)
        #expect(try fixture.progress("first") == finishedAtEnd())
    }

    @Test("Finishing reports the stop at the end: a pause as a pause, a skip as the end of the Book")
    func stopsReported() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        var stops = player.stops().makeAsyncIterator()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3580)

        player.pause()
        #expect(await stops.next() == PlaybackStop(bookID: "first", position: 3600, reason: .paused))

        player.setFinished(false, bookID: "first")
        await fixture.settle()
        player.play()
        fixture.audio.advance(to: 3550)
        player.skip(by: 30)
        #expect(await stops.next() == PlaybackStop(bookID: "first", position: 3600, reason: .endOfBook))
    }

    @Test("Pausing earlier than that leaves the Book unfinished where it is")
    func pauseEarlier() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3560)

        player.pause()

        #expect(!player.isFinished)
        #expect(player.position == 3560)
        #expect(try fixture.progress("first")?.isFinished == false)
    }

    @Test("Skipping forward into the last 30 s stops playing and finishes the Book, at the end")
    func skipNearEnd() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3550)

        player.skip(by: 30)
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
        #expect(player.isFinished)
        #expect(player.position == 3600)
        #expect(fixture.audio.currentTime == 3600)
        #expect(try fixture.progress("first") == finishedAtEnd())
    }

    @Test("Switching to another Book within the last 30 s of this one finishes it")
    func switchNearEnd() async throws {
        try fixture.addBook("first", duration: 3600)
        try fixture.addBook("second")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 3590)

        await player.play(bookID: "second")

        #expect(try fixture.progress("first") == finishedAtEnd())
        #expect(player.book?.id == "second")
        #expect(player.state == .playing)
    }

    @Test("Play on the Finished Book starts it again from 0 and clears Finished")
    func playAgain() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.playToEnd(at: 3600)

        player.play()
        await fixture.settle()

        #expect(player.state == .playing)
        #expect(!player.isFinished)
        #expect(player.position == 0)
        #expect(fixture.audio.currentTime == 0)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 0, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("Marking a Book Finished by hand puts it at the end; clearing it moves it to 0")
    func byHandNotLoaded() async throws {
        try fixture.addBook("first", duration: 3600, downloaded: false)
        try fixture.saveProgress("first", position: 1200, at: fixture.clock.now - 60)
        let player = fixture.player()

        player.setFinished(true, bookID: "first")
        #expect(try fixture.progress("first") == finishedAtEnd())

        await fixture.advance(by: .seconds(10))
        player.setFinished(false, bookID: "first")
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 0, lastChanged: fixture.clock.now, isFinished: false))
        #expect(player.book == nil)
    }

    @Test("Marking the playing Book Finished by hand stops it at the end; clearing it moves it to 0, paused")
    func byHandLoaded() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1000)

        player.setFinished(true, bookID: "first")
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
        #expect(player.isFinished)
        #expect(player.position == 3600)
        #expect(try fixture.progress("first") == finishedAtEnd())

        player.setFinished(false, bookID: "first")
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(!player.isFinished)
        #expect(player.position == 0)
        #expect(fixture.audio.currentTime == 0)
        #expect(try fixture.progress("first")?.isFinished == false)
        #expect(try fixture.progress("first")?.position == 0)
    }
}

extension BookProgress {
    func with(lastChanged: Date) -> BookProgress {
        BookProgress(bookID: bookID, position: position, lastChanged: lastChanged, isFinished: isFinished)
    }
}
