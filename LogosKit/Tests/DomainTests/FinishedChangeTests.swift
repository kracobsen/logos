import Domain
import Foundation
import Testing

@Suite("Finished changes: the fetch-first guard")
struct FinishedChangeTests {
    let acted = Date(millisecondsSince1970: 1_800_000_000_000)

    func change(_ isFinished: Bool) -> FinishedChange {
        FinishedChange(bookID: "a", isFinished: isFinished, position: isFinished ? 3600 : 0, lastUpdate: acted)
    }

    func server(finished: Bool, at lastUpdate: Int64) -> FetchedProgress {
        FetchedProgress(bookID: "a", position: 100, isFinished: finished, lastUpdate: lastUpdate)
    }

    @Test("A Server change made after the listener acted overrules the change")
    func newerServerWins() {
        #expect(FinishedChanges.isOverruled(change(true), by: server(finished: false, at: 1_800_000_000_001)))
    }

    @Test("An older or same-time Server state doesn't (ties keep the local change)")
    func olderOrSameServerLoses() {
        #expect(!FinishedChanges.isOverruled(change(true), by: server(finished: false, at: 1_800_000_000_000)))
        #expect(!FinishedChanges.isOverruled(change(true), by: server(finished: false, at: 1_799_999_999_999)))
    }

    @Test("No Server progress never overrules")
    func noServerProgress() {
        #expect(!FinishedChanges.isOverruled(change(true), by: nil))
    }

    @Test("The Server already has the Finished state: nothing to send")
    func alreadyOnServer() {
        #expect(FinishedChanges.isOnServer(change(true), server: server(finished: true, at: 1)))
        #expect(FinishedChanges.isOnServer(change(false), server: server(finished: false, at: 1)))
        #expect(FinishedChanges.isOnServer(change(false), server: nil))
        #expect(!FinishedChanges.isOnServer(change(true), server: server(finished: false, at: 1)))
        #expect(!FinishedChanges.isOnServer(change(true), server: nil))
        #expect(!FinishedChanges.isOnServer(change(false), server: server(finished: true, at: 1)))
    }
}
