import Domain
import Foundation
import Playback
import Store
import Testing
import UI

extension BookDetailModelTests {
    @Test("Book detail sets Finished by hand (at the end) and clears it (back to 0)")
    func finishedByHand() async throws {
        try database.applyLibraryList([book(duration: 120)], syncedAt: clock.now)
        try database.saveProgress(
            BookProgress(bookID: "first-light", position: 50, lastChanged: clock.now - 60, isFinished: false))
        let model = library().detail(for: "first-light")
        let observing = Task { await model.progress.observe() }
        defer { observing.cancel() }
        #expect(!model.isFinished)

        model.setFinished(true, player: nil)
        await eventually { model.isFinished }
        #expect(model.progress.status == .finished)
        #expect(try database.progress(ofBook: "first-light")?.position == 120)

        model.setFinished(false, player: nil)
        await eventually { !model.isFinished }
        #expect(model.progress.status == .notStarted)
        #expect(try database.progress(ofBook: "first-light")?.position == 0)
    }

    @Test("Through the player, which saves with its own clock")
    func finishedByHandThroughPlayer() async throws {
        try database.applyLibraryList([book(duration: 120)], syncedAt: clock.now)
        let downloads = directory.appending(path: "Downloads")
        let player = Player(
            database: database, files: try DownloadFiles(directory: downloads), audio: FakeAudioPlayer(),
            clock: clock)
        let model = library().detail(for: "first-light")

        model.setFinished(true, player: player)

        #expect(
            try database.progress(ofBook: "first-light")
                == BookProgress(bookID: "first-light", position: 120, lastChanged: clock.now, isFinished: true))
    }
}
