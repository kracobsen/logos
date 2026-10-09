import Domain
import Foundation
import Playback
import Store
import Testing
import UI

extension BookDetailModelTests {
    @Test("Book detail sets Finished by hand (at the end) and clears it (back to 0), stamped with the player's clock")
    func finishedByHand() async throws {
        try database.applyLibraryList([book(duration: 120)], syncedAt: clock.now)
        try database.saveProgress(
            BookProgress(bookID: "first-light", position: 50, lastChanged: clock.now - 60, isFinished: false))
        let player = Player(
            database: database, files: try DownloadFiles(directory: directory.appending(path: "Downloads")),
            audio: FakeAudioPlayer(), clock: clock)
        let model = library().detail(for: "first-light")
        let observing = Task { await model.progress.observe() }
        defer { observing.cancel() }
        #expect(!model.isFinished)

        model.setFinished(true, player: player)
        await eventually { model.isFinished }
        #expect(model.progress.status == .finished)
        #expect(
            try database.progress(ofBook: "first-light")
                == BookProgress(bookID: "first-light", position: 120, lastChanged: clock.now, isFinished: true))

        await clock.advance(by: .seconds(5))
        model.setFinished(false, player: player)
        await eventually { !model.isFinished }
        #expect(model.progress.status == .notStarted)
        #expect(
            try database.progress(ofBook: "first-light")
                == BookProgress(bookID: "first-light", position: 0, lastChanged: clock.now, isFinished: false))
    }
}
