import Domain
import Foundation
import Synchronization
import Testing

@Suite("TestClock")
struct TestClockTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("now starts where it was set and moves only when advanced")
    func nowMovesOnlyWhenAdvanced() async {
        let clock = TestClock(now: start)
        #expect(clock.now == start)

        await clock.advance(by: .seconds(90))

        #expect(clock.now == start.addingTimeInterval(90))
    }

    @Test("a sleeper wakes once time reaches its deadline, and not before")
    func sleeperWakesAtDeadline() async throws {
        let clock = TestClock(now: start)
        let woke = Flag()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(60))
            woke.set()
        }

        await clock.advance(by: .seconds(59))
        #expect(!woke.isSet)

        await clock.advance(by: .seconds(1))
        try await sleeper.value
        #expect(woke.isSet)
    }

    @Test("cancelling a sleeper throws CancellationError without advancing time")
    func cancellingASleeperThrows() async {
        let clock = TestClock(now: start)
        let sleeper = Task { try await clock.sleep(for: .seconds(60)) }

        await clock.advance(by: .zero)
        sleeper.cancel()

        await #expect(throws: CancellationError.self) { try await sleeper.value }
        #expect(clock.now == start)
    }

    @Test("a timer ticks once per interval, with the time of each tick")
    func timerTicksPerInterval() async {
        let clock = TestClock(now: start)
        let ticks = Task {
            var seen: [Date] = []
            for await tick in clock.timer(every: .seconds(1)) {
                seen.append(tick)
                if seen.count == 3 { break }
            }
            return seen
        }

        await clock.advance(by: .seconds(3))

        #expect(
            await ticks.value == [
                start.addingTimeInterval(1), start.addingTimeInterval(2), start.addingTimeInterval(3),
            ])
    }
}

/// A thread-safe boolean for observing another task from a test.
final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
