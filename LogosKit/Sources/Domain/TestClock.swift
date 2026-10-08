import Foundation
import Synchronization

/// A ``Clock`` for tests: time stands still until the test calls ``advance(by:)``.
///
/// `advance(by:)` steps through every sleeper's deadline in order, so a ``Clock/timer(every:)``
/// ticks once per interval even when the test advances by several intervals at once.
/// Before and after waking sleepers it yields so that tasks the test just started get to run
/// and start sleeping.
public final class TestClock: Clock {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [UInt64: Sleeper] = [:]
        var nextID: UInt64 = 0
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        state = Mutex(State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: (any Error)?? = state.withLock { state in
                    if Task.isCancelled { return .some(CancellationError()) }
                    if duration <= .zero { return .some(nil) }
                    let deadline = state.now.addingTimeInterval(duration.timeInterval)
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .none
                }
                switch resumeNow {
                case .none: break
                case .some(.none): continuation.resume()
                case .some(.some(let error)): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration`, waking each sleeper at its deadline along the way.
    public func advance(by duration: Duration) async {
        await Self.settle()
        let target = now.addingTimeInterval(duration.timeInterval)
        while true {
            let due: [Sleeper] = state.withLock { state in
                guard let next = state.sleepers.values.map(\.deadline).min(), next <= target else {
                    state.now = target
                    return []
                }
                state.now = next
                let ids = state.sleepers.filter { $0.value.deadline == next }.map(\.key)
                return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
            }
            if due.isEmpty { break }
            for sleeper in due { sleeper.continuation.resume() }
            await Self.settle()
        }
        await Self.settle()
    }

    /// Gives other tasks a chance to run up to their next suspension point.
    private static func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
