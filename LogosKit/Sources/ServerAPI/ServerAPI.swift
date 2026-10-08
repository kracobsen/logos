import Domain
import Foundation

/// The network seam: every call Logos makes to the Server.
///
/// ``AudiobookshelfClient`` is the real implementation; ``FakeServer`` is the scripted one for unit tests. Calls are
/// stateless: the Server's base URL and any token are passed in. ``Auth`` owns the tokens and wraps authenticated
/// calls (``Auth/authorized(_:)``), so callers never handle a 401 or a refresh themselves.
///
/// The protocol doesn't enforce HTTPS, so integration tests can reach the plain-HTTP Docker Server. The HTTPS-only
/// rule lives in sign-in, where the Server URL is chosen.
public protocol ServerAPI: Sendable {
    /// `GET /status` (no auth): the version and the allowed sign-in methods.
    func status(of server: URL) async throws(ServerAPIError) -> ServerStatus

    /// `POST /login` with `x-return-tokens: true`. A 401 means wrong username or password (or an inactive user).
    func logIn(to server: URL, username: String, password: String) async throws(ServerAPIError) -> SignedInUser

    /// `POST /auth/refresh` with `x-refresh-token`. Returns the rotated pair. A 401 means the Server rejected the
    /// refresh token: Needs sign-in.
    func refresh(on server: URL, refreshToken: String) async throws(ServerAPIError) -> SignedInUser

    /// `GET /api/libraries`: every Library the user can access, podcast ones included.
    func libraries(on server: URL, accessToken: String) async throws(ServerAPIError) -> [ServerLibrary]

    /// `GET /api/libraries/:id/items?limit=0`: every Book in the Library, as list data. A list that can't be read
    /// as a whole is `unreadableResponse`.
    func books(inLibrary libraryID: String, on server: URL, accessToken: String) async throws(ServerAPIError)
        -> [ListedBook]

    /// `POST /api/items/batch/get`: full data for the given Books (`ids` must not be empty). Books the Server doesn't
    /// know, and Books it sends that can't be read, are left out.
    func bookData(for ids: [String], on server: URL, accessToken: String) async throws(ServerAPIError) -> [BookData]

    /// `GET /api/items/:id?expanded=1`: full data for one Book. 404 if the Server doesn't know it.
    func bookData(for id: String, on server: URL, accessToken: String) async throws(ServerAPIError) -> BookData
}

/// Why a Server call failed.
public enum ServerAPIError: Error, Sendable, Hashable {
    /// The request never got an HTTP response: offline, DNS, TLS, timeout, refused connection.
    case unreachable(String)
    /// HTTP 401.
    case unauthorized
    /// HTTP 429 (the sign-in and refresh rate limit).
    case rateLimited
    /// Any other non-2xx status.
    case unexpectedStatus(Int)
    /// A 2xx response whose body isn't what audiobookshelf sends.
    case unreadableResponse
}

/// What `GET /status` says about a Server.
public struct ServerStatus: Sendable, Hashable {
    /// The version as reported, e.g. `"2.37.1"`, for messages.
    public let reportedVersion: String
    /// The parsed version, or `nil` if it can't be read (treat as unsupported).
    public let version: ServerVersion?
    /// Whether `authMethods` contains `local` (username and password).
    public let allowsLocalSignIn: Bool

    public init(reportedVersion: String, allowsLocalSignIn: Bool) {
        self.reportedVersion = reportedVersion
        self.version = ServerVersion(reportedVersion)
        self.allowsLocalSignIn = allowsLocalSignIn
    }

    /// Whether Logos supports this Server's version.
    public var isSupported: Bool { version?.isSupported ?? false }
}

/// The user and token pair from a login or a refresh.
public struct SignedInUser: Sendable, Hashable {
    /// The Server's user id. Signing in again must match it.
    public let id: String
    public let username: String
    public let tokens: TokenPair

    public init(id: String, username: String, tokens: TokenPair) {
        self.id = id
        self.username = username
        self.tokens = tokens
    }
}

/// A Library as the Server lists it.
public struct ServerLibrary: Sendable, Hashable, Identifiable {
    public enum MediaType: Sendable, Hashable {
        case book
        case podcast
        case other(String)
    }

    public let id: String
    public let name: String
    public let mediaType: MediaType

    public init(id: String, name: String, mediaType: MediaType) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
    }
}
