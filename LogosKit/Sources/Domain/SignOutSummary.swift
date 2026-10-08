import Foundation

/// What signing out will remove, for the confirmation: the Downloads on this iPhone, and what the outbox still holds
/// after the last try to send it (lost with the wipe).
public struct SignOutSummary: Sendable, Hashable {
    /// Downloaded Books.
    public var downloadCount: Int
    /// The space Downloads take on disk, partial ones included.
    public var downloadBytes: Int64
    /// Listening sessions the Server hasn't confirmed.
    public var unsentSessionCount: Int
    /// Finished changes the Server hasn't confirmed.
    public var unsentFinishedChangeCount: Int

    public init(downloadCount: Int, downloadBytes: Int64, unsentSessionCount: Int, unsentFinishedChangeCount: Int) {
        self.downloadCount = downloadCount
        self.downloadBytes = downloadBytes
        self.unsentSessionCount = unsentSessionCount
        self.unsentFinishedChangeCount = unsentFinishedChangeCount
    }

    /// Listening that would be lost: unsent sessions or Finished changes.
    public var losesListening: Bool { unsentSessionCount > 0 || unsentFinishedChangeCount > 0 }
}
