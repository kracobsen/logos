import Foundation

/// How the Downloaded tab sorts the downloaded Books.
public enum DownloadedOrder: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Most recently listened first; never-listened ones last. The default.
    case recentlyListened
    /// The biggest Downloads first, to free space.
    case largestFirst

    public var id: Self { self }

    public var title: String {
        switch self {
        case .recentlyListened: "Recently listened"
        case .largestFirst: "Largest first"
        }
    }
}

extension DownloadsList {
    /// The downloaded Books in `order`. Equal sizes keep the recently listened order.
    public func downloaded(in order: DownloadedOrder) -> [DownloadRow] {
        switch order {
        case .recentlyListened:
            return downloaded
        case .largestFirst:
            return downloaded.enumerated()
                .sorted {
                    $0.element.totalBytes != $1.element.totalBytes
                        ? $0.element.totalBytes > $1.element.totalBytes : $0.offset < $1.offset
                }
                .map(\.element)
        }
    }
}
