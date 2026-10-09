/// An audiobookshelf version as `/status` reports it (`serverVersion`, e.g. `"2.37.1"`).
///
/// Logos supports 2.36 and later only, with no fallbacks for older Servers. The version is checked at sign-in and
/// at every sync.
public struct ServerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The oldest supported Server.
    public static let minimumSupported = ServerVersion(components: [2, 36, 0], description: "2.36.0")

    /// Numeric components, major first. Missing trailing components count as 0.
    let components: [Int]

    /// The text the Server reported, for messages such as "Server too old".
    public let description: String

    private init(components: [Int], description: String) {
        self.components = components
        self.description = description
    }

    /// Reads a dotted numeric version. Returns `nil` for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            components.append(value)
        }
        self.init(components: components, description: text)
    }

    /// Whether Logos supports this Server.
    public var isSupported: Bool { self >= Self.minimumSupported }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
