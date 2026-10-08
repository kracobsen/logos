import Domain
import Foundation
import Synchronization

/// Hands what a write just did to whoever listens, in memory only: for things the tables can't tell afterwards (a
/// fetched progress row and a local save look alike; a deleted Download leaves nothing behind).
final class Broadcast<Element: Sendable>: Sendable {
    private let listeners = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        listeners.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ element: Element) {
        for continuation in listeners.withLock({ Array($0.values) }) {
            continuation.yield(element)
        }
    }
}

extension AppDatabase {
    /// The progress each applied fetch adopted (one element per fetch that changed something), from now on. Fetches
    /// that changed nothing, and local saves, aren't reported. Shared by every copy of this database value.
    public func fetchedProgressUpdates() -> AsyncStream<[BookProgress]> {
        fetchedProgress.stream()
    }

    /// The Books whose Download stage 1 just deleted because the Server no longer lists them (queued, downloading or
    /// failed: a downloaded one is kept as Not on Server), from now on. Their transfers and files are the
    /// Downloader's to stop and delete.
    public func downloadsRemovedFromLibraryUpdates() -> AsyncStream<Set<String>> {
        downloadsRemovedFromLibrary.stream()
    }
}
