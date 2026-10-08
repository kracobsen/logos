import Domain
import Foundation
import Testing

@Suite("Listening session rules")
struct ListeningSessionsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    func write(_ bookID: String = "a", at seconds: TimeInterval, position: Double, finished: Bool = false)
        -> BookProgress
    {
        BookProgress(
            bookID: bookID, position: position, lastChanged: start.addingTimeInterval(seconds), isFinished: finished)
    }

    func playing(_ bookID: String = "a", since seconds: TimeInterval = 0, listened: Double = 0) -> ListeningSession {
        ListeningSession(
            id: UUID(), bookID: bookID, startTime: 100, currentTime: 100, timeListening: listened,
            startedAt: start, updatedAt: start.addingTimeInterval(seconds),
            listenedUntil: start.addingTimeInterval(seconds), isPlaying: true, isOpen: true)
    }

    func paused(_ bookID: String = "a", at seconds: TimeInterval) -> ListeningSession {
        var session = playing(bookID, since: seconds)
        session.isPlaying = false
        return session
    }

    @Test("Playing with no open session starts one at the position, stamped when Play was pressed")
    func starts() {
        let changed = ListeningSessions.recording(write(at: 0, position: 100), isPlaying: true, open: []) { id }
        #expect(
            changed == [
                ListeningSession(
                    id: id, bookID: "a", startTime: 100, currentTime: 100, timeListening: 0, startedAt: start,
                    updatedAt: start, listenedUntil: start, isPlaying: true, isOpen: true)
            ])
    }

    @Test("A write while paused with no open session starts nothing")
    func pausedWriteStartsNothing() {
        #expect(ListeningSessions.recording(write(at: 0, position: 100), isPlaying: false, open: []).isEmpty)
    }

    @Test("Each write while playing adds the real seconds since the last one, whatever the Book time moved")
    func countsRealSeconds() throws {
        // At 2x, a second of real time moves the position two seconds.
        let changed = ListeningSessions.recording(
            write(at: 1, position: 102), isPlaying: true, open: [playing(listened: 0)])
        let session = try #require(changed.first)
        #expect(session.timeListening == 1)
        #expect(session.currentTime == 102)
        #expect(session.updatedAt == start.addingTimeInterval(1))
        #expect(session.startTime == 100)
    }

    @Test("Time paused isn't counted, and a pause shorter than 10 minutes keeps the session")
    func shortPauseContinues() throws {
        let open = paused(at: 10)
        let changed = ListeningSessions.recording(
            write(at: 10 + 9 * 60 + 59, position: 100), isPlaying: true, open: [open])
        let session = try #require(changed.first)
        #expect(changed.count == 1)
        #expect(session.id == open.id)
        #expect(session.timeListening == 0)
        #expect(session.isOpen)
    }

    @Test("Playing after a pause of 10 minutes or more ends the old session and starts another")
    func longPauseEnds() {
        let open = paused(at: 10)
        let changed = ListeningSessions.recording(
            write(at: 10 + 10 * 60, position: 100), isPlaying: true, open: [open]
        ) { id }
        #expect(changed.map(\.id) == [open.id, id])
        #expect(changed.map(\.isOpen) == [false, true])
    }

    @Test("Playing another Book ends the open session of the one before")
    func bookSwitchEnds() {
        let other = paused("b", at: 0)
        let changed = ListeningSessions.recording(write(at: 30, position: 0), isPlaying: true, open: [other]) { id }
        #expect(changed.map(\.id) == [other.id, id])
        #expect(changed.map(\.isOpen) == [false, true])
    }

    @Test("A seek in another Book while paused leaves the open session alone")
    func pausedWriteElsewhereKeeps() {
        #expect(
            ListeningSessions.recording(write(at: 30, position: 0), isPlaying: false, open: [paused("b", at: 0)])
                .isEmpty)
    }

    @Test("A Finished write ends the session")
    func finishedEnds() throws {
        let changed = ListeningSessions.recording(
            write(at: 1, position: 3600, finished: true), isPlaying: false, open: [playing()])
        let session = try #require(changed.first)
        #expect(!session.isOpen)
        #expect(session.timeListening == 1)
        #expect(session.currentTime == 3600)
    }
}
