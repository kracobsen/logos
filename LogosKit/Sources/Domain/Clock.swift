import Foundation

/// The Clock seam: the current wall-clock time, plus sleeping and timers.
///
/// Injected into Sync, Downloads and Playback so that last-writer-wins timestamps, the 60 s sends,
/// the 10-minute session gap, backoff, refreshing ahead of time and the Sleep Timer are all testable.
/// Use ``SystemClock`` in the app and ``TestClock`` in tests. Never call `Date()` or `Task.sleep`
/// directly in those modules.
public protocol Clock: Sendable {
    /// The current wall-clock time.
    var now: Date { get }

    /// Suspends for `duration`. Throws `CancellationError` if the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

extension Clock {
    /// Ticks with the current time every `interval`, starting one interval from now,
    /// until the consumer stops iterating.
    public func timer(every interval: Duration) -> AsyncStream<Date> {
        AsyncStream { continuation in
            let task = Task {
                while true {
                    do {
                        try await sleep(for: interval)
                    } catch {
                        break
                    }
                    continuation.yield(now)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The real clock: `Date()` for now, and the continuous clock for sleeping.
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: .continuous)
    }
}
