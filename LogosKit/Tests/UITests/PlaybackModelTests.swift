import Domain
import Foundation
import Playback
import ServerAPI
import Store
import Testing
import UI

extension DownloadsModelTests {
    /// A player over the same Downloads directory as the Downloader, with a fake AVPlayer.
    func player(_ audio: FakeAudioPlayer = FakeAudioPlayer()) throws -> Player {
        Player(
            database: database, files: try DownloadFiles(directory: directory.appending(path: "Downloads")),
            audio: audio, clock: clock)
    }

    func downloaded(_ id: String) async {
        await downloader.download(id)
        await server.transfers.completeAll()
    }

    @Test("Removing the Download of the Book that's playing stops playback first, saving the position")
    func removePlaying() async throws {
        await downloaded("first")
        let audio = FakeAudioPlayer()
        let player = try player(audio)
        let model = model()
        model.player = player
        await player.play(bookID: "first")
        audio.advance(to: 12)

        await model.cancel("first")

        #expect(player.state == .idle)
        #expect(audio.loadedFiles == nil)
        #expect(try database.progress(ofBook: "first")?.position == 12)
        #expect(try database.downloadStatus(ofBook: "first") == nil)
    }

    @Test("The Series \"Continue with Book N\" button plays that Book and stays on the page")
    func seriesContinuePlays() async throws {
        await downloaded("first")
        let player = try player()
        let page = SeriesPageModel(seriesID: "saga", name: "Saga", database: database, sync: sync)
        #expect(page.continueTarget?.action == .play)

        let opened = page.continueTapped(downloads: model(), player: player)

        #expect(opened == nil)
        await eventually { player.state == .playing }
        #expect(player.book?.id == "first")
    }

    @Test("A downloaded Book's button offers Play, Resume once started, and Pause while it plays")
    func playActions() async throws {
        await downloaded("first")
        let audio = FakeAudioPlayer()
        let player = try player(audio)

        #expect(player.action(forBook: "first", resumes: false) == .play)
        #expect(player.action(forBook: "first", resumes: true) == .resume)

        player.tapped(bookID: "first")
        await eventually { player.state == .playing }
        #expect(player.action(forBook: "first", resumes: false) == .pause)
        #expect(player.action(forBook: "second", resumes: false) == .play)

        audio.advance(to: 5)
        player.tapped(bookID: "first")
        #expect(player.state == .paused)
        #expect(player.action(forBook: "first", resumes: false) == .resume)
    }
}
