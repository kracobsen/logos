import Domain
import Foundation

/// The real ``ServerAPI``: audiobookshelf over `URLSession`.
///
/// Uses an ephemeral session with cookies off, so the Server's httpOnly refresh cookie never mixes with the tokens
/// ``Auth`` keeps.
public struct AudiobookshelfClient: ServerAPI {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        self.init(session: URLSession(configuration: configuration))
    }

    /// Uses `session` as given. Prefer ``init()``; the session must not store cookies.
    public init(session: URLSession) {
        self.session = session
    }

    public func status(of server: URL) async throws(ServerAPIError) -> ServerStatus {
        try Responses.status(await send(Requests.status(server)))
    }

    public func logIn(to server: URL, username: String, password: String) async throws(ServerAPIError) -> SignedInUser {
        try Responses.signedInUser(await send(Requests.logIn(server, username: username, password: password)))
    }

    public func refresh(on server: URL, refreshToken: String) async throws(ServerAPIError) -> SignedInUser {
        try Responses.signedInUser(await send(Requests.refresh(server, refreshToken: refreshToken)))
    }

    public func libraries(on server: URL, accessToken: String) async throws(ServerAPIError) -> [ServerLibrary] {
        try Responses.libraries(await send(Requests.libraries(server, accessToken: accessToken)))
    }

    public func books(inLibrary libraryID: String, on server: URL, accessToken: String) async throws(ServerAPIError)
        -> [ListedBook]
    {
        try Responses.books(await send(Requests.books(inLibrary: libraryID, on: server, accessToken: accessToken)))
    }

    public func progress(on server: URL, accessToken: String) async throws(ServerAPIError) -> [FetchedProgress] {
        try Responses.progress(await send(Requests.progress(server, accessToken: accessToken)))
    }

    public func cover(ofBook bookID: String, on server: URL, accessToken: String) async throws(ServerAPIError) -> Data {
        try await send(Requests.cover(ofBook: bookID, on: server, accessToken: accessToken))
    }

    private func send(_ request: URLRequest) async throws(ServerAPIError) -> Data {
        // Paths only: never log the host, tokens or bodies.
        let endpoint = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let reason = error.localizedDescription
            log.info("\(endpoint, privacy: .public) failed: \(reason, privacy: .public)")
            throw .unreachable(reason)
        }
        guard let http = response as? HTTPURLResponse else { throw .unreadableResponse }
        if let error = Responses.error(forStatusCode: http.statusCode) {
            log.info("\(endpoint, privacy: .public) returned \(http.statusCode)")
            throw error
        }
        return data
    }
}
