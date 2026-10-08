import Domain
import Foundation
import Synchronization

/// Hands the progress each applied fetch adopted to whoever listens (the Player, to pick up a paused Book moved on
/// another device). In memory only: it tells this process what a fetch just changed, which the `progress` table
/// can't (a fetched row and a local save look alike there).
final class FetchedProgressBroadcast: Sendable {
    private let listeners = Mutex<[UUID: AsyncStream<[BookProgress]>.Continuation]>([:])

    func stream() -> AsyncStream<[BookProgress]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [BookProgress].self)
        let id = UUID()
        listeners.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ adopted: [BookProgress]) {
        for continuation in listeners.withLock({ Array($0.values) }) {
            continuation.yield(adopted)
        }
    }
}

extension AppDatabase {
    /// The progress each applied fetch adopted (one element per fetch that changed something), from now on. Fetches
    /// that changed nothing, and local saves, aren't reported. Shared by every copy of this database value.
    public func fetchedProgressUpdates() -> AsyncStream<[BookProgress]> {
        fetchedProgress.stream()
    }
}
