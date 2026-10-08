import Foundation

/// An access and refresh token pair. Never the legacy non-expiring `user.token`.
///
/// Lifetimes are read from the JWTs' `exp` claims, never hard-coded.
public struct TokenPair: Sendable, Hashable, Codable {
    public let accessToken: String
    public let refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    /// When the access token expires, or `nil` if its `exp` can't be read.
    public var accessTokenExpiry: Date? { Self.expiry(of: accessToken) }

    /// When the refresh token expires, or `nil` if its `exp` can't be read.
    public var refreshTokenExpiry: Date? { Self.expiry(of: refreshToken) }

    /// Reads `exp` (seconds since 1970) from a JWT's base64url payload. The signature isn't checked: the Server
    /// does that, and the claim only decides when to refresh.
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: base64),
            let claims = try? JSONDecoder().decode(Claims.self, from: data),
            let exp = claims.exp
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private struct Claims: Decodable {
        let exp: TimeInterval?
    }
}
