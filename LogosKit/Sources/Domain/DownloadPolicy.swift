/// How Downloads may use the network and the disk: the "Allow downloads over cellular" setting, and whether the queue
/// is paused for lack of storage.
public struct DownloadPolicy: Sendable, Hashable {
    /// Off by default: Downloads use Wi-Fi only. Constrained networks (Low Data Mode) are never used either way.
    public var allowsCellular: Bool
    /// The last free-space check failed: no Book starts until a check passes (on the next return to the
    /// foreground, or when space is freed in Logos).
    public var isPausedForStorage: Bool

    public init(allowsCellular: Bool = false, isPausedForStorage: Bool = false) {
        self.allowsCellular = allowsCellular
        self.isPausedForStorage = isPausedForStorage
    }

    public static let `default` = DownloadPolicy()
}
