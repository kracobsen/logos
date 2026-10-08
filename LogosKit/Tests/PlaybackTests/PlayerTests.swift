import Domain
import Foundation
import Playback
import Testing

@Suite("The player engine")
@MainActor
struct PlayerTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    @Test("Playing a downloaded Book loads its files back to back and plays from its saved position")
    func playFromSavedPosition() async throws {
        try fixture.addBook("first", fileCount: 2)
        try fixture.saveProgress("first", position: 1234.5, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()

        await player.play(bookID: "first")

        #expect(fixture.audio.loadedFiles == fixture.fileURLs("first", count: 2))
        #expect(fixture.audio.currentTime == 1234.5)
        #expect(fixture.audio.isPlaying)
        #expect(player.state == .playing)
        #expect(player.book?.id == "first")
        #expect(player.position == 1234.5)
    }

    @Test("While playing, the position and the current Chapter follow the player")
    func publishesPosition() async throws {
        try fixture.addBook("first", chapters: PlayerFixture.chapters(3600, every: 600))
        let player = fixture.player()
        await player.play(bookID: "first")
        #expect(player.chapterIndex == 0)

        fixture.audio.advance(to: 600.25)

        #expect(player.position == 600.25)
        #expect(player.chapterIndex == 1)
        #expect(player.chapter?.title == "Chapter 2")
    }

    @Test("While playing, the position is saved every second with when the listener acted")
    func savesEverySecond() async throws {
        try fixture.addBook("first")
        let started = fixture.clock.now
        let player = fixture.player()
        await player.play(bookID: "first")

        fixture.audio.advance(to: 10.5)
        await fixture.advance(by: .seconds(1))
        let saved = try fixture.progress("first")
        #expect(
            saved
                == BookProgress(
                    bookID: "first", position: 10.5, lastChanged: started.addingTimeInterval(1), isFinished: false))

        fixture.audio.advance(to: 11.5)
        await fixture.advance(by: .milliseconds(1500))
        #expect(try fixture.progress("first")?.position == 11.5)
        #expect(try fixture.progress("first")?.lastChanged == started.addingTimeInterval(2))
        _ = player
    }

    @Test("Pausing saves at once, and nothing more is saved while paused")
    func pauseSaves() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 42.25)
        await fixture.advance(by: .milliseconds(300))

        player.pause()

        let paused = BookProgress(
            bookID: "first", position: 42.25, lastChanged: fixture.clock.now, isFinished: false)
        #expect(try fixture.progress("first") == paused)
        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)

        await fixture.advance(by: .seconds(5))
        #expect(try fixture.progress("first") == paused)
    }

    @Test("Resuming plays on from where it paused, without rewinding")
    func resumeDoesNotRewind() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 100)
        player.pause()
        let seeksBefore = fixture.audio.seeks

        player.play()

        #expect(fixture.audio.isPlaying)
        #expect(fixture.audio.seeks == seeksBefore)
        #expect(fixture.audio.currentTime == 100)
        #expect(player.state == .playing)
    }

    @Test("A seek moves the position at once and saves; the player's stale times are ignored until it lands")
    func seek() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 100)
        fixture.audio.holdsSeeks = true

        player.seek(to: 2000)

        #expect(player.position == 2000)
        #expect(try fixture.progress("first")?.position == 2000)
        #expect(try fixture.progress("first")?.lastChanged == fixture.clock.now)
        await fixture.settle()
        fixture.audio.advance(to: 1999)  // a report from before the seek landed
        #expect(player.position == 2000)

        await fixture.audio.finishSeeks()
        fixture.audio.advance(to: 2000.5)
        #expect(player.position == 2000.5)
        #expect(fixture.audio.seeks.last == 2000)
    }

    @Test("Skips move by their interval within the Book, and Chapter jumps go to the Chapter's start; each saves")
    func skipsAndChapterJumps() async throws {
        try fixture.addBook("first", duration: 3600, chapters: PlayerFixture.chapters(3600, every: 600))
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 100)

        player.skip(by: 30)
        #expect(player.position == 130)
        player.skip(by: -15)
        #expect(player.position == 115)
        player.skip(by: -300)
        #expect(player.position == 0)
        player.jump(toChapter: 2)
        #expect(player.position == 1200)
        #expect(player.chapterIndex == 2)
        #expect(try fixture.progress("first")?.position == 1200)
        player.skip(by: 9999)
        #expect(player.position == 3600)
        await fixture.settle()
        #expect(fixture.audio.seeks.suffix(5) == [130, 115, 0, 1200, 3600])
    }

    @Test("Playing another Book saves the current one and starts the new one at its position, no questions asked")
    func switchBooks() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second", fileCount: 1)
        try fixture.saveProgress("second", position: 500, at: fixture.clock.now.addingTimeInterval(-3600))
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 77)
        await fixture.advance(by: .milliseconds(500))

        await player.play(bookID: "second")

        #expect(try fixture.progress("first")?.position == 77)
        #expect(try fixture.progress("first")?.lastChanged == fixture.clock.now)
        #expect(player.book?.id == "second")
        #expect(player.state == .playing)
        #expect(player.position == 500)
        #expect(fixture.audio.loadedFiles == fixture.fileURLs("second", count: 1))
        #expect(fixture.audio.currentTime == 500)
        #expect(fixture.audio.isPlaying)
    }

    @Test("Play on a Finished Book starts it from the beginning and it's no longer Finished")
    func playFinished() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress(
            "first", position: 3600, at: fixture.clock.now.addingTimeInterval(-60), isFinished: true)
        let player = fixture.player()

        await player.play(bookID: "first")
        await fixture.settle()

        #expect(player.position == 0)
        #expect(!player.isFinished)
        #expect(fixture.audio.currentTime == 0)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 0, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("Launch restores the last-played Book paused at its position, and never plays it")
    func restoreAtLaunch() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second")
        try fixture.saveProgress("first", position: 50, at: fixture.clock.now.addingTimeInterval(-600))
        try fixture.saveProgress("second", position: 250, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()

        await player.restoreLastPlayed()
        await fixture.advance(by: .seconds(3))

        #expect(player.book?.id == "second")
        #expect(player.state == .paused)
        #expect(player.position == 250)
        #expect(fixture.audio.currentTime == 250)
        #expect(!fixture.audio.isPlaying)
        // Restoring isn't listening: the saved progress is untouched.
        #expect(try fixture.progress("second")?.lastChanged == fixture.clock.now.addingTimeInterval(-63))
    }

    @Test("Restoring at launch leaves a Book the listener already started alone")
    func restoreAfterPlay() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second")
        try fixture.saveProgress("second", position: 250, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()
        await player.play(bookID: "first")

        await player.restoreLastPlayed()

        #expect(player.book?.id == "first")
        #expect(player.state == .playing)
    }

    @Test("Going to the background saves the position at once while playing")
    func background() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        await fixture.advance(by: .milliseconds(1250))
        fixture.audio.advance(to: 33.3)

        player.enteredBackground()

        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 33.3, lastChanged: fixture.clock.now, isFinished: false))
        #expect(player.state == .playing)
    }

    @Test("A Book that isn't downloaded doesn't play")
    func notDownloaded() async throws {
        try fixture.addBook("first", downloaded: false)
        let player = fixture.player()

        await player.play(bookID: "first")

        #expect(fixture.audio.loadedFiles == nil)
        #expect(player.state == .idle)
        #expect(player.book == nil)
        #expect(player.problem == .notDownloaded)
        #expect(try fixture.progress("first") == nil)
    }

    @Test("A Book whose file is missing doesn't play, and its progress is kept")
    func missingFile() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 10, at: fixture.clock.now)
        try FileManager.default.removeItem(at: fixture.fileURLs("first")[1])
        let player = fixture.player()

        await player.play(bookID: "first")

        #expect(player.state == .idle)
        #expect(player.problem == .cannotOpen)
        #expect(!fixture.audio.isPlaying)
        #expect(try fixture.progress("first")?.position == 10)
    }

    @Test("Stopping the loaded Book (before its Download is removed) pauses, saves and unloads it")
    func stopForRemoval() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 90)

        player.stop(bookID: "second")
        #expect(player.state == .playing)

        player.stop(bookID: "first")

        #expect(player.state == .idle)
        #expect(player.book == nil)
        #expect(fixture.audio.loadedFiles == nil)
        #expect(try fixture.progress("first")?.position == 90)
        await fixture.advance(by: .seconds(2))
        #expect(try fixture.progress("first")?.position == 90)
    }

    @Test("At the end of the Book playing stops, saved at the end")
    func endOfBook() async throws {
        try fixture.addBook("first", duration: 3600)
        let player = fixture.player()
        await player.play(bookID: "first")

        fixture.audio.playToEnd(at: 3600)

        #expect(player.state == .paused)
        #expect(player.position == 3600)
        #expect(try fixture.progress("first")?.position == 3600)
    }

    @Test("A decode failure reloads the Book and plays on from a second earlier (FB22340742)")
    func decodeWorkaround() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1500)
        let loads = fixture.audio.loadCount

        fixture.audio.failToDecode()
        await fixture.settle()

        #expect(fixture.audio.loadCount == loads + 1)
        #expect(fixture.audio.currentTime == 1499)
        #expect(fixture.audio.isPlaying)
        #expect(player.state == .playing)
        #expect(player.problem == nil)
    }

    @Test("A Book that keeps failing to decode pauses and saves after ten reloads")
    func decodeGivesUp() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1500)
        for _ in 0..<Player.maxDecodeRetries {
            fixture.audio.failToDecode()
            await fixture.settle()
            fixture.audio.advance(to: 1500)
        }
        let loads = fixture.audio.loadCount

        fixture.audio.failToDecode()
        await fixture.settle()

        #expect(fixture.audio.loadCount == loads)
        #expect(player.state == .paused)
        #expect(player.problem == .cannotDecode)
        #expect(try fixture.progress("first")?.position == 1500)
    }

    @Test("A Chapter tapped on Book detail loads the Book and plays from the Chapter's start")
    func playFromChapter() async throws {
        try fixture.addBook("first", chapters: PlayerFixture.chapters(3600, every: 600))
        try fixture.saveProgress("first", position: 100, at: fixture.clock.now.addingTimeInterval(-60))
        let player = fixture.player()

        await player.play(bookID: "first", from: 1800)
        await fixture.settle()

        #expect(player.position == 1800)
        #expect(player.chapterIndex == 3)
        #expect(fixture.audio.currentTime == 1800)
        #expect(fixture.audio.isPlaying)
        #expect(try fixture.progress("first")?.position == 1800)
    }

    @Test("The speed applies to the player and is published")
    func rate() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")

        player.setRate(1.5)

        #expect(fixture.audio.rate == 1.5)
        #expect(player.rate == 1.5)
    }
}
