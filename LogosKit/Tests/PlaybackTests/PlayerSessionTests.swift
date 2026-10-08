import Domain
import Foundation
import Playback
import Testing

/// Collects the stops the engine reports.
@MainActor
final class StopRecorder {
    private(set) var received: [PlaybackStop] = []
    private(set) var task: Task<Void, Never>!

    init(_ stops: AsyncStream<PlaybackStop>) {
        task = Task { [weak self] in
            for await stop in stops { self?.received.append(stop) }
        }
    }
}

@Suite("The player engine around interruptions, routes and media-services resets")
@MainActor
struct PlayerSessionTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    @Test("An interruption pauses and saves")
    func interruptionPausesAndSaves() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 42.5)
        await fixture.advance(by: .milliseconds(300))

        fixture.session.send(.interrupted)

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 42.5, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("After an interruption, playing resumes where it paused when the system recommends it")
    func resumesWhenRecommended() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 100)
        fixture.session.send(.interrupted)
        let seeksBefore = fixture.audio.seeks

        fixture.session.send(.interruptionEnded(shouldResume: true))

        #expect(player.state == .playing)
        #expect(fixture.audio.isPlaying)
        #expect(fixture.audio.seeks == seeksBefore)
        #expect(fixture.audio.currentTime == 100)
    }

    @Test("After an interruption, playing stays paused when the system doesn't recommend resuming")
    func staysPausedWhenNotRecommended() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.session.send(.interrupted)

        fixture.session.send(.interruptionEnded(shouldResume: false))

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }

    @Test("A Book that was paused when the interruption came stays paused, whatever the system recommends")
    func pausedBookNeverResumes() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        player.pause()

        fixture.session.send(.interrupted)
        fixture.session.send(.interruptionEnded(shouldResume: true))

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }

    @Test("A Book the listener paused again after playing during the interruption doesn't resume when it ends")
    func listenerPauseWins() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.session.send(.interrupted)
        player.play()
        player.pause()

        fixture.session.send(.interruptionEnded(shouldResume: true))

        #expect(player.state == .paused)
    }

    @Test("Resuming after an interruption is only for the Book that was interrupted")
    func otherBookDoesNotResume() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.session.send(.interrupted)
        player.stop(bookID: "first")
        await player.restoreLastPlayed()

        fixture.session.send(.interruptionEnded(shouldResume: true))

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }

    @Test("Losing the route (headphones or Bluetooth gone) pauses and saves")
    func routeLossPausesAndSaves() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 77.25)
        await fixture.advance(by: .milliseconds(300))

        fixture.session.send(.routeLost)

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 77.25, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("After losing the route, playing never resumes by itself, even when an interruption ends with resume")
    func routeLossNeverResumes() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.session.send(.interrupted)
        fixture.session.send(.routeLost)

        fixture.session.send(.interruptionEnded(shouldResume: true))
        fixture.session.send(.routeAdded)

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }

    @Test("A new route keeps playing and saves")
    func newRouteKeepsPlayingAndSaves() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 300.5)
        await fixture.advance(by: .milliseconds(300))

        fixture.session.send(.routeAdded)

        #expect(player.state == .playing)
        #expect(fixture.audio.isPlaying)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 300.5, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("A new route leaves a paused Book paused")
    func newRouteLeavesPausedBookPaused() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        player.pause()

        fixture.session.send(.routeAdded)

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }

    @Test("A media-services reset while playing rebuilds the player paused at the saved position")
    func resetWhilePlaying() async throws {
        try fixture.addBook("first", fileCount: 3, chapters: PlayerFixture.chapters(3600, every: 600))
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 610.5)
        await fixture.advance(by: .seconds(1))
        fixture.audio.advance(to: 610.75)  // published, not saved yet; the old player is gone
        let saved = try fixture.progress("first")

        fixture.session.send(.mediaServicesReset)
        await fixture.settle()

        #expect(fixture.audio.rebuildCount == 1)
        #expect(fixture.audio.loadCount == 2)
        #expect(fixture.audio.loadedFiles == fixture.fileURLs("first", count: 3))
        #expect(fixture.audio.currentTime == 610.5)
        #expect(!fixture.audio.isPlaying)
        #expect(player.state == .paused)
        #expect(player.book?.id == "first")
        #expect(player.position == 610.5)
        #expect(player.chapterIndex == 1)
        #expect(try fixture.progress("first") == saved)

        await fixture.advance(by: .seconds(3))
        #expect(try fixture.progress("first") == saved)
    }

    @Test("A media-services reset while paused rebuilds the player paused where it was, and it plays from there")
    func resetWhilePaused() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 55)
        player.pause()

        fixture.session.send(.mediaServicesReset)
        await fixture.settle()

        #expect(fixture.audio.rebuildCount == 1)
        #expect(fixture.audio.currentTime == 55)
        #expect(player.state == .paused)

        player.play()
        #expect(fixture.audio.isPlaying)
        #expect(player.state == .playing)
        #expect(fixture.audio.currentTime == 55)
    }

    @Test("A media-services reset with no Book loaded just rebuilds the player")
    func resetWithNothingLoaded() async throws {
        let player = fixture.player()

        fixture.session.send(.mediaServicesReset)
        await fixture.settle()

        #expect(fixture.audio.rebuildCount == 1)
        #expect(fixture.audio.loadCount == 0)
        #expect(player.state == .idle)
    }

    @Test(
        "Each way the system stops playing is reported with its reason, after saving",
        arguments: [
            (AudioSessionEvent.interrupted, PlaybackStop.Reason.interrupted),
            (.routeLost, .routeLost),
            (.mediaServicesReset, .mediaServicesReset),
        ])
    func reportsStops(event: AudioSessionEvent, reason: PlaybackStop.Reason) async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let stops = StopRecorder(player.stops())
        await player.play(bookID: "first")
        fixture.audio.advance(to: 12)
        await fixture.advance(by: .seconds(1))

        fixture.session.send(event)
        await fixture.settle()

        #expect(stops.received == [PlaybackStop(bookID: "first", position: 12, reason: reason)])
        stops.task.cancel()
    }

    @Test("The Sleep Timer survives an interruption and a media-services reset, and still stops at its Chapter's end")
    func sleepTimerSurvives() async throws {
        try fixture.addBook("first", chapters: PlayerFixture.chapters(3600, every: 600))
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 900)
        player.setSleepTimer(chapters: 1)

        fixture.session.send(.interrupted)
        fixture.session.send(.interruptionEnded(shouldResume: true))
        fixture.session.send(.mediaServicesReset)
        await fixture.settle()
        #expect(player.sleepTimer != nil)

        player.play()
        fixture.audio.advance(to: 1200.2)
        await fixture.settle()

        #expect(player.state == .paused)
        #expect(try fixture.progress("first")?.position == 1200)
    }

    @Test("A media-services reset doesn't resume after an interruption that was going on")
    func resetForgetsInterruption() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.session.send(.interrupted)

        fixture.session.send(.mediaServicesReset)
        await fixture.settle()
        fixture.session.send(.interruptionEnded(shouldResume: true))

        #expect(player.state == .paused)
        #expect(!fixture.audio.isPlaying)
    }
}
