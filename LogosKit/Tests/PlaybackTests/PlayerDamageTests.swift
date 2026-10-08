import Domain
import Foundation
import Playback
import Testing

@Suite("The player and damaged Downloads")
@MainActor
struct PlayerDamageTests {
    let fixture: PlayerFixture

    init() throws {
        fixture = try PlayerFixture()
    }

    private func expectDamaged(
        _ player: Player, _ id: String = "first", notOnServer: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(
            player.damaged
                == DamagedDownload(bookID: id, title: "Title \(id)", isNotOnServer: notOnServer),
            sourceLocation: sourceLocation)
        #expect(try fixture.database.downloadStatus(ofBook: id) == nil, sourceLocation: sourceLocation)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.files.folder(forBook: id).path(percentEncoded: false)),
            sourceLocation: sourceLocation)
        #expect(try fixture.database.downloadQueue().isEmpty, "nothing downloads again", sourceLocation: sourceLocation)
    }

    @Test("A missing file is caught at play time: nothing plays, the Book is no longer downloaded, progress is kept")
    func missingFile() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 10, at: fixture.clock.now - 60, isFinished: false)
        try FileManager.default.removeItem(at: fixture.fileURLs("first")[1])
        let player = fixture.player()

        await player.play(bookID: "first")

        #expect(fixture.audio.loadedFiles == nil)
        #expect(player.state == .idle)
        #expect(player.problem == .damagedFiles)
        try expectDamaged(player)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 10, lastChanged: fixture.clock.now - 60, isFinished: false))
    }

    @Test("A wrong-size file is caught at play time, before the player opens it")
    func wrongSize() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 3600, at: fixture.clock.now - 60, isFinished: true)
        try Data(count: 999).write(to: fixture.fileURLs("first")[0])
        let player = fixture.player()

        await player.play(bookID: "first")

        #expect(fixture.audio.loadCount == 0)
        #expect(player.state == .idle)
        try expectDamaged(player)
        #expect(try fixture.progress("first")?.isFinished == true)
        #expect(try fixture.progress("first")?.position == 3600)
    }

    @Test("A file the player can't open is damage too")
    func cannotOpen() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        fixture.audio.failsToLoad = true

        await player.play(bookID: "first")

        #expect(player.problem == .cannotOpen)
        try expectDamaged(player)
    }

    @Test("A decode failure that reloading doesn't fix pauses, saves, and marks the Download damaged")
    func decodeMidPlay() async throws {
        try fixture.addBook("first")
        let player = fixture.player()
        await player.play(bookID: "first")
        fixture.audio.advance(to: 1500)
        for _ in 0..<Player.maxDecodeRetries {
            fixture.audio.failToDecode()
            await fixture.settle()
            fixture.audio.advance(to: 1500)
        }

        fixture.audio.failToDecode()
        await fixture.settle()

        #expect(!fixture.audio.isPlaying)
        #expect(player.problem == .cannotDecode)
        #expect(player.state == .idle)
        #expect(player.book == nil)
        try expectDamaged(player)
        #expect(
            try fixture.progress("first")
                == BookProgress(bookID: "first", position: 1500, lastChanged: fixture.clock.now, isFinished: false))
    }

    @Test("A damaged Not on Server Book stays, without its Download, and says it's no longer on the Server")
    func notOnServer() async throws {
        try fixture.addBook("first")
        try fixture.addBook("second")
        try fixture.removeFromServer("first")
        try FileManager.default.removeItem(at: fixture.fileURLs("first")[0])
        let player = fixture.player()

        await player.play(bookID: "first")

        try expectDamaged(player, notOnServer: true)
        #expect(try fixture.database.bookDetail(id: "first")?.isNotOnServer == true)
    }

    @Test("Dismissing the damage notice clears it; playing again finds the Book not downloaded")
    func dismiss() async throws {
        try fixture.addBook("first")
        try FileManager.default.removeItem(at: fixture.fileURLs("first")[0])
        let player = fixture.player()
        await player.play(bookID: "first")

        player.dismissDamage()
        #expect(player.damaged == nil)

        await player.play(bookID: "first")
        #expect(player.problem == .notDownloaded)
        #expect(player.damaged == nil)
    }

    @Test("A damaged last-played Book found at launch is marked not downloaded without a notice")
    func restore() async throws {
        try fixture.addBook("first")
        try fixture.saveProgress("first", position: 50, at: fixture.clock.now - 60)
        try FileManager.default.removeItem(at: fixture.fileURLs("first")[0])
        let player = fixture.player()

        await player.restoreLastPlayed()

        #expect(player.book == nil)
        #expect(player.damaged == nil)
        #expect(try fixture.database.downloadStatus(ofBook: "first") == nil)
        #expect(try fixture.progress("first")?.position == 50)
    }
}
