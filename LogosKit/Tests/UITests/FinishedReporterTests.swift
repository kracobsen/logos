import Domain
import Foundation
import Playback
import ServerAPI
import Store
import Sync
import Testing
import UI

extension ListeningReporterTests {
    var finishedPatches: Int {
        server.requests.filter { if case .updateFinished = $0 { true } else { false } }.count
    }

    @Test("Finished set by hand on a Book that isn't playing is sent straight away")
    func sendsFinishedByHand() async throws {
        let player = player()
        let reporter = reporter(player)
        let running = Task { await reporter.run() }
        defer { running.cancel() }
        await eventually { server.requests.count > 0 }  // the launch send found nothing
        try await Task.sleep(for: .milliseconds(50))
        #expect(finishedPatches == 0)

        player.setFinished(true, bookID: "first")

        await eventually { finishedPatches == 1 }
        #expect(finishedPatches == 1)
        #expect(server.progress.first?.isFinished == true)
    }
}
