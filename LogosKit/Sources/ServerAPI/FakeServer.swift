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
        /// `POST /logout` with the refresh token.
        case logOut(URL, refreshToken: String)
        case libraries(URL, accessToken: String)
        case books(URL, libraryID: String, accessToken: String)
        case bookDataBatch(URL, ids: [String], accessToken: String)
        case bookData(URL, id: String, accessToken: String)
        case progress(URL, accessToken: String)
        case cover(URL, bookID: String, accessToken: String)
        /// `POST /api/session/local-all`, with the sent sessions.
        case syncSessions(URL, sessions: [OutboxSession], device: ClientDevice, accessToken: String)
        /// `PATCH /api/me/progress/:libraryItemId` with a Finished change.
        case updateFinished(URL, change: FinishedChange, duration: Double, accessToken: String)
        /// A background file transfer being answered (``FakeFileTransfers``).
        case file(URL, bookID: String, ino: String, accessToken: String, resuming: Bool)
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
        var bookData: [BookData] = []
        var progress: [FetchedProgress] = []
        var covers: [String: Data] = [:]
        var sessions: [String: ListeningSession] = [:]
        var stampsFirstProgressWithServerTime = false
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
    private let fileTransfers = Mutex<FakeFileTransfers?>(nil)

    /// This Server's background file transfers.
    public var transfers: FakeFileTransfers {
        fileTransfers.withLock { stored in
            if let stored { return stored }
            let created = FakeFileTransfers(server: self)
            stored = created
            return created
        }
    }

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

    /// Full data for listed Books, served by the `bookData` calls. A listed Book without an entry here gets its list
    /// data with no Chapters, tracks or Series. Default: none.
    public var bookData: [BookData] {
        get { state.withLock { $0.bookData } }
        set { state.withLock { $0.bookData = newValue } }
    }

    /// The signed-in user's progress, as `GET /api/me/progress` returns it. Default: none.
    public var progress: [FetchedProgress] {
        get { state.withLock { $0.progress } }
        set { state.withLock { $0.progress = newValue } }
    }

    /// The cover data per Book id. A Book without one gets a 404. Default: none.
    public var covers: [String: Data] {
        get { state.withLock { $0.covers } }
        set { state.withLock { $0.covers = newValue } }
    }

    /// The listening sessions received, by id, in their latest state. Default: none.
    public var sessions: [String: ListeningSession] {
        get { state.withLock { $0.sessions } }
        set { state.withLock { $0.sessions = newValue } }
    }

    /// Like 2.37.1, a session that creates a Book's first progress stamps it with the Server's time (the clock's
    /// now), not the session's `updatedAt`. Default: off (the session's `updatedAt`), which older tests rely on.
    public var stampsFirstProgressWithServerTime: Bool {
        get { state.withLock { $0.stampsFirstProgressWithServerTime } }
        set { state.withLock { $0.stampsFirstProgressWithServerTime = newValue } }
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

    /// Signs `account` in without a request, as if it had signed in before: for seeding a signed-in app.
    public func issueTokens(for account: Account) -> SignedInUser {
        state.withLock { issue(for: account, in: &$0) }
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

    /// Like 2.37.1: revokes the refresh token (an unknown one is still a 200). Access tokens already issued stay
    /// valid until they expire.
    public func logOut(on server: URL, refreshToken: String) async throws(ServerAPIError) {
        try await receive(.logOut(server, refreshToken: refreshToken), at: server)
        state.withLock { _ = $0.refreshTokens.removeValue(forKey: refreshToken) }
    }

    /// Whether the Server would still accept this refresh token (not revoked, logged out or used).
    public func accepts(refreshToken: String) -> Bool {
        state.withLock { $0.refreshTokens[refreshToken] != nil }
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

    public func bookData(for ids: [String], on server: URL, accessToken: String) async throws(ServerAPIError)
        -> [BookData]
    {
        try await receive(.bookDataBatch(server, ids: ids, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [BookData] in
            try authenticate(accessToken, in: state)
            guard !ids.isEmpty else { throw .unexpectedStatus(403) }
            return ids.compactMap { fullData(for: $0, in: state) }
        }
    }

    public func bookData(for id: String, on server: URL, accessToken: String) async throws(ServerAPIError) -> BookData {
        try await receive(.bookData(server, id: id, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> BookData in
            try authenticate(accessToken, in: state)
            guard let data = fullData(for: id, in: state) else { throw .unexpectedStatus(404) }
            return data
        }
    }

    public func progress(on server: URL, accessToken: String) async throws(ServerAPIError) -> [FetchedProgress] {
        try await receive(.progress(server, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [FetchedProgress] in
            try authenticate(accessToken, in: state)
            return state.progress
        }
    }

    public func cover(ofBook bookID: String, on server: URL, accessToken: String) async throws(ServerAPIError) -> Data {
        try await receive(.cover(server, bookID: bookID, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> Data in
            try authenticate(accessToken, in: state)
            guard let data = state.covers[bookID] else { throw .unexpectedStatus(404) }
            return data
        }
    }

    /// Like 2.37.1: a session for a Book the Server doesn't list fails on its own ("Media item not found"); others
    /// are stored (latest state wins) and move the Book's progress unless the progress is newer than the session's
    /// `updatedAt`. Moving progress to within 10 s of the end finishes the Book; moving a Finished Book's progress
    /// anywhere else clears Finished. Creating a Book's first progress never finishes it.
    public func syncSessions(
        _ sessions: [OutboxSession], device: ClientDevice, libraryID: String, on server: URL, accessToken: String
    ) async throws(ServerAPIError) -> [SessionResult] {
        try await receive(
            .syncSessions(server, sessions: sessions, device: device, accessToken: accessToken), at: server)
        return try state.withLock { (state) throws(ServerAPIError) -> [SessionResult] in
            try authenticate(accessToken, in: state)
            return sessions.map { entry in
                let session = entry.session
                guard state.books.contains(where: { $0.id == session.bookID }) else {
                    return SessionResult(id: session.serverID, isDelivered: false, error: "Media item not found")
                }
                state.sessions[session.serverID] = session
                let updatedAt = session.updatedAt.millisecondsSince1970
                let index = state.progress.firstIndex { $0.bookID == session.bookID }
                if let index, state.progress[index].lastUpdate > updatedAt {
                    return SessionResult(id: session.serverID, isDelivered: true)
                }
                guard let index else {
                    let stamp = state.stampsFirstProgressWithServerTime ? clock.now.millisecondsSince1970 : updatedAt
                    state.progress.append(
                        FetchedProgress(
                            bookID: session.bookID, position: session.currentTime, isFinished: false,
                            lastUpdate: stamp))
                    return SessionResult(id: session.serverID, isDelivered: true)
                }
                let stored = state.progress[index]
                let duration = state.books.first { $0.id == session.bookID }?.duration ?? 0
                let nearEnd = duration > 0 && duration - session.currentTime < 10
                let isFinished =
                    nearEnd || (stored.isFinished && stored.position == session.currentTime)
                state.progress[index] = FetchedProgress(
                    bookID: session.bookID, position: session.currentTime, isFinished: isFinished,
                    lastUpdate: updatedAt)
                return SessionResult(id: session.serverID, isDelivered: true)
            }
        }
    }

    /// Like 2.37.1: 404 for a Book the Server doesn't list. Finished takes the sent position; clearing a Finished
    /// Book puts it at 0. An existing record takes `lastUpdate`; a new one gets the Server's time (the clock's now).
    public func updateFinished(_ change: FinishedChange, duration: Double, on server: URL, accessToken: String)
        async throws(ServerAPIError)
    {
        try await receive(
            .updateFinished(server, change: change, duration: duration, accessToken: accessToken), at: server)
        try state.withLock { (state) throws(ServerAPIError) in
            try authenticate(accessToken, in: state)
            guard state.books.contains(where: { $0.id == change.bookID }) else { throw .unexpectedStatus(404) }
            let index = state.progress.firstIndex { $0.bookID == change.bookID }
            let wasFinished = index.map { state.progress[$0].isFinished } ?? false
            let position = !change.isFinished && wasFinished ? 0 : change.position
            let progress = FetchedProgress(
                bookID: change.bookID, position: position, isFinished: change.isFinished,
                lastUpdate: index == nil ? clock.now.millisecondsSince1970 : change.lastUpdate.millisecondsSince1970)
            if let index { state.progress[index] = progress } else { state.progress.append(progress) }
        }
    }

    // MARK: For FakeFileTransfers

    func receiveFileRequest(_ request: FileTransferRequest) async throws(ServerAPIError) {
        let file = Request.file(
            request.server, bookID: request.transfer.bookID, ino: request.ino, accessToken: request.accessToken,
            resuming: request.resumeData != nil)
        try await receive(file, at: request.server)
    }

    func accepts(accessToken: String) -> Bool {
        state.withLock { state in
            do {
                try authenticate(accessToken, in: state)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: Internals

    private func fullData(for id: String, in state: State) -> BookData? {
        guard let listed = state.books.first(where: { $0.id == id }) else { return nil }
        return state.bookData.first { $0.book.id == id }
            ?? BookData(book: listed, chapters: [], tracks: [], series: [])
    }

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
