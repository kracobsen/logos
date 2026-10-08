import Domain
import Foundation
import Synchronization

/// A scripted audiobookshelf for unit tests: the fake side of the ``ServerAPI`` seam.
///
/// It behaves like a small 2.37.1 Server at ``address``: it checks passwords, issues JWT-shaped tokens whose `exp`
/// follows the injected clock, rejects expired or revoked access tokens with 401, and rotates refresh tokens. Tests
/// script the rest:
/// - set ``version``, ``authMethods``, ``libraries`` or ``accounts`` to shape the Server;
/// - ``isReachable`` makes requests fail as if offline;
/// - ``beforeHandling(_:)`` runs before each request is handled, to hold it open or throw an error;
/// - ``requests`` lists what the Server received, in order.
public final class FakeServer: ServerAPI {
    public struct Account: Sendable, Hashable {
        public var id: String
        public var username: String
        public var password: String

        public init(id: String, username: String, password: String) {
            self.id = id
            self.username = username
            self.password = password
        }

        public static let listener = Account(id: "user-listener", username: "listener", password: "listenerpass")
    }

    /// A request the Server received.
    public enum Request: Sendable, Hashable {
        case status(URL)
        case logIn(URL, username: String)
        case refresh(URL, refreshToken: String)
        case libraries(URL, accessToken: String)
        case books(URL, libraryID: String, accessToken: String)
        case progress(URL, accessToken: String)
    }

    public typealias Hook = @Sendable (Request) async throws(ServerAPIError) -> Void

    /// The message of the `unreachable` error for requests ``isReachable`` turns away.
    public static let unreachableMessage = "The fake Server is unreachable"

    private struct State {
        var version: String
        var authMethods: [String]
        var accounts: [Account]
        var libraries: [ServerLibrary]
        var books: [ListedBook] = []
        var progress: [FetchedProgress] = []
        var requests: [Request] = []
        var isReachable: @Sendable (Request) -> Bool = { _ in true }
        var hook: Hook?
        var accessTokens: [String: String] = [:]  // token -> user id
        var refreshTokens: [String: String] = [:]  // token -> user id
        var issued = 0
    }

    /// Where the Server answers. Requests to any other URL fail as unreachable.
    public let address: URL
    private let clock: any Clock
    private let accessTokenLifetime: Duration
    private let refreshTokenLifetime: Duration
    private let state: Mutex<State>

    public init(
        address: URL = URL(string: "https://abs.example.com")!,
        version: String = "2.37.1",
        authMethods: [String] = ["local"],
        accounts: [Account] = [.listener],
        libraries: [ServerLibrary] = [ServerLibrary(id: "library-books", name: "Audiobooks", mediaType: .book)],
        clock: any Clock,
        accessTokenLifetime: Duration = .seconds(60 * 60),
        refreshTokenLifetime: Duration = .seconds(30 * 24 * 60 * 60)
    ) {
        self.address = address
        self.clock = clock
        self.accessTokenLifetime = accessTokenLifetime
        self.refreshTokenLifetime = refreshTokenLifetime
        state = Mutex(State(version: version, authMethods: authMethods, accounts: accounts, libraries: libraries))
    }

    // MARK: Scripting

    public var version: String {
        get { state.withLock { $0.version } }
        set { state.withLock { $0.version = newValue } }
    }

    public var authMethods: [String] {
        get { state.withLock { $0.authMethods } }
        set { state.withLock { $0.authMethods = newValue } }
    }

    public var accounts: [Account] {
        get { state.withLock { $0.accounts } }
        set { state.withLock { $0.accounts = newValue } }
    }

    public var libraries: [ServerLibrary] {
        get { state.withLock { $0.libraries } }
        set { state.withLock { $0.libraries = newValue } }
    }

    /// The Books in every book Library the Server lists. Default: none.
    public var books: [ListedBook] {
        get { state.withLock { $0.books } }
        set { state.withLock { $0.books = newValue } }
    }

    /// The signed-in user's progress, as `GET /api/me/progress` returns it. Default: none.
    public var progress: [FetchedProgress] {
        get { state.withLock { $0.progress } }
        set { state.withLock { $0.progress = newValue } }
    }

    /// Decides per request whether it gets through. Default: everything does.
    public var isReachable: @Sendable (Request) -> Bool {
        get { state.withLock { $0.isReachable } }
        set { state.withLock { $0.isReachable = newValue } }
    }

    /// Every request received so far, in order (including ones that then failed).
    public var requests: [Request] {
        state.withLock { $0.requests }
    }

    /// Runs `hook` before each request is handled (after it is recorded). Throwing fails the request.
    public func beforeHandling(_ hook: Hook?) {
        state.withLock { $0.hook = hook }
    }

    /// Makes every access token issued so far fail with 401, as after a Server restart with a new secret.
    public func revokeAccessTokens() {
        state.withLock { $0.accessTokens = [:] }
    }

    /// Makes every refresh token issued so far fail with 401, as after a sign-out elsewhere.
    public func revokeRefreshTokens() {
        state.withLock { $0.refreshTokens = [:] }
    }

    // MARK: ServerAPI

    public func status(of server: URL) async throws(ServerAPIError) -> ServerStatus {
        try await receive(.status(server), at: server)
        return state.withLock {
            ServerStatus(reportedVersion: $0.version, allowsLocalSignIn: $0.authMethods.contains("local"))
        }
    }

    public func logIn(to server: URL, username: String, password: String) async throws(ServerAPIError) -> SignedInUser {
        try await receive(.logIn(server, username: username), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> SignedInUser in
            guard
                state.authMethods.contains("local"),
                let account = state.accounts.first(where: {
                    $0.username.lowercased() == username.lowercased() && $0.password == password
                })
            else { throw .unauthorized }
            return issue(for: account, in: &state)
        }
    }

    public func refresh(on server: URL, refreshToken: String) async throws(ServerAPIError) -> SignedInUser {
        try await receive(.refresh(server, refreshToken: refreshToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> SignedInUser in
            guard
                let userID = state.refreshTokens.removeValue(forKey: refreshToken),
                let expiry = TokenPair.expiry(of: refreshToken), expiry > clock.now,
                let account = state.accounts.first(where: { $0.id == userID })
            else { throw .unauthorized }
            return issue(for: account, in: &state)
        }
    }

    public func libraries(on server: URL, accessToken: String) async throws(ServerAPIError) -> [ServerLibrary] {
        try await receive(.libraries(server, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [ServerLibrary] in
            try authenticate(accessToken, in: state)
            return state.libraries
        }
    }

    public func books(inLibrary libraryID: String, on server: URL, accessToken: String) async throws(ServerAPIError)
        -> [ListedBook]
    {
        try await receive(.books(server, libraryID: libraryID, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [ListedBook] in
            try authenticate(accessToken, in: state)
            guard state.libraries.contains(where: { $0.id == libraryID && $0.mediaType == .book }) else {
                throw .unexpectedStatus(404)
            }
            return state.books
        }
    }

    public func progress(on server: URL, accessToken: String) async throws(ServerAPIError) -> [FetchedProgress] {
        try await receive(.progress(server, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [FetchedProgress] in
            try authenticate(accessToken, in: state)
            return state.progress
        }
    }

    // MARK: Internals

    private func receive(_ request: Request, at server: URL) async throws(ServerAPIError) {
        let (hook, reachable) = state.withLock { state in
            state.requests.append(request)
            return (state.hook, state.isReachable(request))
        }
        guard reachable, server == address else { throw .unreachable(Self.unreachableMessage) }
        try await hook?(request)
    }

    private func authenticate(_ accessToken: String, in state: State) throws(ServerAPIError) {
        guard
            state.accessTokens[accessToken] != nil,
            let expiry = TokenPair.expiry(of: accessToken), expiry > clock.now
        else { throw .unauthorized }
    }

    private func issue(for account: Account, in state: inout State) -> SignedInUser {
        state.issued += 1
        let now = clock.now
        let access = Self.jwt(
            userID: account.id,
            type: "access",
            serial: state.issued,
            expiry: now.addingTimeInterval(Self.seconds(accessTokenLifetime))
        )
        let refresh = Self.jwt(
            userID: account.id,
            type: "refresh",
            serial: state.issued,
            expiry: now.addingTimeInterval(Self.seconds(refreshTokenLifetime))
        )
        state.accessTokens[access] = account.id
        state.refreshTokens[refresh] = account.id
        return SignedInUser(
            id: account.id,
            username: account.username,
            tokens: TokenPair(accessToken: access, refreshToken: refresh)
        )
    }

    private static func jwt(userID: String, type: String, serial: Int, expiry: Date) -> String {
        func base64url(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims =
            #"{"userId":"\#(userID)","type":"\#(type)","jti":"\#(serial)","exp":\#(Int(expiry.timeIntervalSince1970))}"#
        return "\(base64url(#"{"alg":"HS256","typ":"JWT"}"#)).\(base64url(claims)).fake-signature"
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

extension FakeServer {
    /// A Book for scripting ``books``, with list data made up from the title.
    public static func book(
        _ title: String,
        id: String? = nil,
        authorName: String = "Ada Fixture",
        updatedAt: Int64 = 1_700_000_000_000
    ) -> ListedBook {
        ListedBook(
            id: id ?? "book-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
            mediaID: "media-\(id ?? title)",
            title: title,
            subtitle: nil,
            authorName: authorName,
            authorNameLF: authorName,
            narratorName: "",
            seriesName: "",
            description: nil,
            publishedYear: nil,
            genres: [],
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt,
            duration: 3600,
            size: 1_000_000,
            hasCover: false
        )
    }
}
