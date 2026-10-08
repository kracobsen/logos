import Domain
import Foundation
import NowPlaying
import Store
import Testing

@testable import Playback

@Suite("Now Playing on the lock screen and in Control Center")
@MainActor
struct NowPlayingTests {
    let fixture: PlayerFixture
    let center = FakeNowPlayingCenter()

    init() throws {
        fixture = try PlayerFixture()
    }

    /// Chapters of 600 s: "Chapter 1" 0–600, "Chapter 2" 600–1200, … over a 3600 s Book.
    func follow(_ player: Player) -> Task<Void, Never> {
        let nowPlaying = NowPlaying(player: player, center: center, covers: nil, clock: fixture.clock)
        return Task { await nowPlaying.follow() }
    }

    @Test("Shows the Chapter name as the title and the Book title and author as the subtitle")
    func titles() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 700, at: fixture.clock.now)
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }

        await player.play(bookID: "first")
        await fixture.settle()

        let item = try #require(center.state?.item)
        #expect(item.title == "Chapter 2")
        #expect(item.subtitle == "Title first · Ada Author")
        #expect(item.chapterNumber == 2)
        #expect(item.chapterCount == 6)
    }

    @Test("Progress is Chapter-scoped: the Chapter's length, the time into it, and the speed while playing")
    func chapterScopedProgress() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 700, at: fixture.clock.now)
        let player = fixture.player()
        player.setSpeed(1.5)
        let following = follow(player)
        defer { following.cancel() }

        await player.play(bookID: "first")
        await fixture.settle()

        let state = try #require(center.state)
        #expect(state.item.chapterStart == 600)
        #expect(state.item.duration == 600)
        #expect(state.playback.elapsed == 100)
        #expect(state.playback.status == .playing(rate: 1.5))
        #expect(state.playback.speed == 1.5)
        #expect(state.playback.date == fixture.clock.now)

        player.pause()
        await fixture.settle()
        #expect(center.state?.playback.status == .paused)
    }

    @Test("The title and progress move on to the next Chapter when playing rolls over")
    func chapterRollover() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 1195, at: fixture.clock.now)
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()

        fixture.audio.advance(by: 10)
        await fixture.settle()

        let state = try #require(center.state)
        #expect(state.item.title == "Chapter 3")
        #expect(state.item.chapterNumber == 3)
        #expect(state.item.chapterStart == 1200)
        #expect(state.playback.elapsed == 5)
    }

    @Test("Playing along isn't re-sent (the system extrapolates), but a jump is")
    func onlyJumpsAreSent() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()
        let sent = center.shown.count

        for _ in 0..<4 {
            fixture.audio.advance(by: 0.5)
            await fixture.advance(by: .milliseconds(500))
        }
        #expect(center.shown.count == sent)

        player.seek(to: 100)
        await fixture.settle()
        #expect(center.shown.count == sent + 1)
        #expect(center.state?.playback.elapsed == 100)
    }

    @Test("Nothing loaded shows nothing")
    func nothingLoaded() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await fixture.settle()
        #expect(center.shown.count == 1)
        #expect(center.state == nil)

        await player.play(bookID: "first")
        await fixture.settle()
        #expect(center.state != nil)

        player.stop(bookID: "first")
        await fixture.settle()
        #expect(center.state == nil)
    }

    @Test("Shows the Book's cover file when there is one")
    func cover() async throws {
        let covers = try CoverFiles(directory: fixture.directory.appending(path: "Covers"))
        try covers.save(Data([0xFF, 0xD8]), forBook: "first")
        try fixture.addBook("first")
        try fixture.addBook("second")
        let player = fixture.player()
        let nowPlaying = NowPlaying(player: player, center: center, covers: covers, clock: fixture.clock)
        let following = Task { await nowPlaying.follow() }
        defer { following.cancel() }

        await player.play(bookID: "first")
        await fixture.settle()
        #expect(center.state?.item.coverURL == covers.url(forBook: "first"))

        await player.play(bookID: "second")
        await fixture.settle()
        #expect(center.state?.item.bookID == "second")
        #expect(center.state?.item.coverURL == nil)
    }

    @Test("After a media-services reset, Now Playing is published again")
    func republishedAfterReset() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 700, at: fixture.clock.now)
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()
        #expect(center.resetCount == 0)

        fixture.session.send(.mediaServicesReset)
        await fixture.settle()

        #expect(center.resetCount == 1)
        let last = try #require(center.shown.last ?? nil)
        #expect(last.item.title == "Chapter 2")
        #expect(last.playback.status == .paused)
    }

    // MARK: - Commands

    @Test("Skip back and forward offer the configured intervals, and follow a change made while a Book is loaded")
    func skipIntervals() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()
        #expect(center.state?.controls.skipBack == 15)
        #expect(center.state?.controls.skipForward == 30)

        player.setSkipBackInterval(.sixty)
        player.setSkipForwardInterval(.ten)
        await fixture.settle()

        #expect(center.state?.controls.skipBack == 60)
        #expect(center.state?.controls.skipForward == 10)
    }

    @Test("Skip and next/previous-track commands skip by the configured intervals (next = forward, previous = back)")
    func skipCommands() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 1000, at: fixture.clock.now)
        let player = fixture.player()
        player.setSkipBackInterval(.ten)
        player.setSkipForwardInterval(.sixty)
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()

        center.send(.skipForward)
        #expect(player.position == 1060)
        center.send(.skipBack)
        #expect(player.position == 1050)
        center.send(.nextTrack)
        #expect(player.position == 1110)
        center.send(.previousTrack)
        #expect(player.position == 1100)

        player.setSkipForwardInterval(.fifteen)
        center.send(.nextTrack)
        #expect(player.position == 1115)
    }

    @Test("Scrubbing moves within the Chapter shown")
    func scrubbing() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 700, at: fixture.clock.now)
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()

        center.send(.seek(to: 30))

        #expect(player.position == 630)
        #expect(try fixture.progress("first")?.position == 630)
    }

    @Test("The speed menu offers the presets and sets the global speed")
    func speedMenu() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()
        #expect(center.state?.controls.speeds == [1.0, 1.25, 1.5, 1.75, 2.0])

        center.send(.changeSpeed(1.75))
        await fixture.settle()

        #expect(player.speed == 1.75)
        #expect(fixture.audio.rate == 1.75)
        #expect(center.state?.playback.status == .playing(rate: 1.75))
    }

    @Test("Play, pause and play/pause control the player")
    func playPause() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        let following = follow(player)
        defer { following.cancel() }
        await player.play(bookID: "first")
        await fixture.settle()

        center.send(.pause)
        #expect(player.state == .paused)
        center.send(.play)
        #expect(player.state == .playing)
        center.send(.togglePlayPause)
        #expect(player.state == .paused)
        center.send(.togglePlayPause)
        #expect(player.state == .playing)
    }

    // MARK: - The system adapter

    @Test("The system gets a BookContent with the Chapter as title, the Book and author as author line, no narrator")
    func bookContent() {
        let item = NowPlayingItem(
            bookID: "first", title: "Chapter 2", subtitle: "Title · Author",
            chapterNumber: 2, chapterCount: 6, chapterStart: 600, duration: 600, coverURL: nil)

        let content = SystemNowPlayingCenter.content(for: item)

        #expect(content.id == "first")
        #expect(content.title == "Chapter 2")
        #expect(content.authorName == "Title · Author")
        #expect(content.narratorName == nil)
        #expect(content.chapter?.current == 2)
        #expect(content.chapter?.total == 6)
        guard case .finite(let duration) = content.duration else {
            Issue.record("not a finite duration")
            return
        }
        #expect(duration == 600)
    }

    @Test("The system session offers the controls and the playing state at the speed, and clears with nothing loaded")
    func systemSession() {
        let system = SystemNowPlayingCenter()
        let item = NowPlayingItem(
            bookID: "first", title: "Chapter 2", subtitle: "Title · Author",
            chapterNumber: 2, chapterCount: 6, chapterStart: 600, duration: 600, coverURL: nil)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let playback = NowPlayingPlayback(status: .playing(rate: 1.5), speed: 1.5, elapsed: 100, date: date)
        let controls = NowPlayingControls(skipBack: 15, skipForward: 30, speeds: [1, 1.25, 1.5, 1.75, 2])

        system.show(NowPlayingState(item: item, playback: playback, controls: controls))

        #expect(system.content?.id == "first")
        #expect(system.commands.count == 9)
        #expect(
            system.playbackSnapshot
                == MediaPlaybackSnapshot(
                    state: .playing(rate: 1.5), defaultPlaybackRate: 1.5, elapsedTime: 100, timestamp: date))

        system.show(nil)
        #expect(system.content == nil)
        #expect(system.commands.isEmpty)
    }
}
