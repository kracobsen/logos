import Foundation

/// The free-space seam: how many bytes the volume Downloads live on can still take.
public protocol StorageCapacity: Sendable {
    /// The volume's available capacity for important usage (what iOS can free for a task the user asked for), or
    /// `nil` if it can't be read.
    func availableForImportantUsage() -> Int64?
}

/// The real one: `volumeAvailableCapacityForImportantUsage` of the volume holding `url`.
public struct VolumeStorageCapacity: StorageCapacity {
    let url: URL

    public init(volumeOf url: URL) {
        self.url = url
    }

    public func availableForImportantUsage() -> Int64? {
        do {
            return try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        } catch {
            log.error("Couldn't read the free space: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
