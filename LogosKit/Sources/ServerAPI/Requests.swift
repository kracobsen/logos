import Foundation

/// Builds the audiobookshelf requests. Paths are appended to the Server URL, so a Server under a path works.
enum Requests {
    static func status(_ server: URL) -> URLRequest {
        URLRequest(url: server.appending(path: "status"))
    }

    static func logIn(_ server: URL, username: String, password: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Must be exactly "true": otherwise the refresh token goes into a cookie instead of the body.
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try? JSONEncoder().encode(["username": username, "password": password])
        return request
    }

    static func refresh(_ server: URL, refreshToken: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "auth/refresh"))
        request.httpMethod = "POST"
        request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
        return request
    }

    static func libraries(_ server: URL, accessToken: String) -> URLRequest {
        authorized(URLRequest(url: server.appending(path: "api/libraries")), accessToken)
    }

    private static func authorized(_ request: URLRequest, _ accessToken: String) -> URLRequest {
        var request = request
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// Reads audiobookshelf responses. Error bodies are mostly plain text, so only the status code is used for errors.
enum Responses {
    /// The error for an HTTP status code, or `nil` for success.
    static func error(forStatusCode code: Int) -> ServerAPIError? {
        switch code {
        case 200..<300: nil
        case 401: .unauthorized
        case 429: .rateLimited
        default: .unexpectedStatus(code)
        }
    }

    static func status(_ data: Data) throws(ServerAPIError) -> ServerStatus {
        struct Body: Decodable {
            let serverVersion: String
            let authMethods: [String]
        }
        let body = try decode(Body.self, data)
        return ServerStatus(reportedVersion: body.serverVersion, allowsLocalSignIn: body.authMethods.contains("local"))
    }

    /// Reads a login or refresh response.
    static func signedInUser(_ data: Data) throws(ServerAPIError) -> SignedInUser {
        struct Body: Decodable {
            struct User: Decodable {
                let id: String
                let username: String
                let accessToken: String
                let refreshToken: String
            }
            let user: User
        }
        let user = try decode(Body.self, data).user
        return SignedInUser(
            id: user.id,
            username: user.username,
            tokens: TokenPair(accessToken: user.accessToken, refreshToken: user.refreshToken)
        )
    }

    static func libraries(_ data: Data) throws(ServerAPIError) -> [ServerLibrary] {
        struct Body: Decodable {
            struct Library: Decodable {
                let id: String
                let name: String
                let mediaType: String
            }
            let libraries: [Library]
        }
        return try decode(Body.self, data).libraries.map { library in
            let mediaType: ServerLibrary.MediaType =
                switch library.mediaType {
                case "book": .book
                case "podcast": .podcast
                default: .other(library.mediaType)
                }
            return ServerLibrary(id: library.id, name: library.name, mediaType: mediaType)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(ServerAPIError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .unreadableResponse
        }
    }
}
