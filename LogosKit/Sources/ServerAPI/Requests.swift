import Domain
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

    static func books(inLibrary libraryID: String, on server: URL, accessToken: String) -> URLRequest {
        let url = server.appending(path: "api/libraries").appending(path: libraryID).appending(path: "items")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "0")])
        return authorized(URLRequest(url: url), accessToken)
    }

    static func progress(_ server: URL, accessToken: String) -> URLRequest {
        authorized(URLRequest(url: server.appending(path: "api/me/progress")), accessToken)
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

    /// Reads the Library list. Strict: if any Book can't be read, the whole list can't, so it's never applied.
    static func books(_ data: Data) throws(ServerAPIError) -> [ListedBook] {
        struct Body: Decodable {
            struct Item: Decodable {
                struct Media: Decodable {
                    struct Metadata: Decodable {
                        let title: String
                        let subtitle: String?
                        let authorName: String?
                        let authorNameLF: String?
                        let narratorName: String?
                        let seriesName: String?
                        let description: String?
                        let publishedYear: String?
                        let genres: [String]?
                    }
                    let id: String
                    let metadata: Metadata
                    let coverPath: String?
                    let duration: Double?
                    let size: Int64?
                }
                let id: String
                let addedAt: Int64
                let updatedAt: Int64
                let media: Media
            }
            let results: [Item]
        }
        return try decode(Body.self, data).results.map { item in
            let metadata = item.media.metadata
            return ListedBook(
                id: item.id,
                mediaID: item.media.id,
                title: metadata.title,
                subtitle: metadata.subtitle,
                authorName: metadata.authorName ?? "",
                authorNameLF: metadata.authorNameLF ?? "",
                narratorName: metadata.narratorName ?? "",
                seriesName: metadata.seriesName ?? "",
                description: metadata.description,
                publishedYear: metadata.publishedYear,
                genres: metadata.genres ?? [],
                addedAt: Date(timeIntervalSince1970: TimeInterval(item.addedAt) / 1000),
                updatedAt: item.updatedAt,
                duration: item.media.duration ?? 0,
                size: item.media.size ?? 0,
                hasCover: item.media.coverPath != nil
            )
        }
    }

    /// Reads every Book's progress. Lenient per record, unlike the Library list: podcast episodes, records without a
    /// library item and records that can't be read are skipped, so one odd record never holds up the others.
    static func progress(_ data: Data) throws(ServerAPIError) -> [FetchedProgress] {
        struct Record: Decodable {
            let libraryItemId: String?
            let mediaItemType: String
            let currentTime: Double?
            let isFinished: Bool
            let lastUpdate: Int64
        }
        struct Lossy: Decodable {
            let record: Record?
            init(from decoder: any Decoder) throws {
                record = try? Record(from: decoder)
            }
        }
        struct Body: Decodable {
            let mediaProgress: [Lossy]
        }
        return try decode(Body.self, data).mediaProgress.compactMap { lossy in
            guard let record = lossy.record, record.mediaItemType == "book", let bookID = record.libraryItemId else {
                return nil
            }
            return FetchedProgress(
                bookID: bookID,
                position: record.currentTime ?? 0,
                isFinished: record.isFinished,
                lastUpdate: record.lastUpdate
            )
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
