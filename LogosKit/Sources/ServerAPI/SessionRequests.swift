import Domain
import Foundation

extension Requests {
    /// `POST /api/session/local-all` with this device and the sessions' latest states.
    ///
    /// The Server's handler isn't guarded, so every session is well-formed: a UUID id, numbers for the times
    /// (`timeListening` in whole seconds, the Server stores an integer), times in ms. `date` and `dayOfWeek` (used for
    /// a new session's listening stats) come from `updatedAt` in `timeZone`.
    static func syncSessions(
        _ sessions: [OutboxSession], device: ClientDevice, libraryID: String, on server: URL, accessToken: String,
        timeZone: TimeZone = .current
    ) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "api/session/local-all"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let body = SyncSessionsBody(
            deviceInfo: .init(
                deviceId: device.deviceID, clientName: device.clientName, clientVersion: device.clientVersion,
                manufacturer: device.manufacturer, model: device.model, sdkVersion: device.sdkVersion),
            sessions: sessions.map { SyncSessionsBody.Session($0, libraryID: libraryID, timeZone: timeZone) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try? encoder.encode(body)
        return request
    }
}

/// The body of `POST /api/session/local-all`.
struct SyncSessionsBody: Encodable {
    struct DeviceInfo: Encodable {
        let deviceId: String
        let clientName: String
        let clientVersion: String
        let manufacturer: String
        let model: String
        let sdkVersion: String
    }

    struct Session: Encodable {
        let id: String
        let libraryItemId: String
        let bookId: String
        let libraryId: String
        let mediaType = "book"
        let episodeId: String? = nil
        let displayTitle: String
        let displayAuthor: String
        let duration: Double
        /// 3 = LOCAL.
        let playMethod = 3
        let mediaPlayer = "AVPlayer"
        let startTime: Double
        let currentTime: Double
        let timeListening: Int
        let startedAt: Int64
        let updatedAt: Int64
        let date: String
        let dayOfWeek: String

        init(_ entry: OutboxSession, libraryID: String, timeZone: TimeZone) {
            let session = entry.session
            id = session.serverID
            libraryItemId = session.bookID
            bookId = entry.mediaID
            self.libraryId = libraryID
            displayTitle = entry.title
            displayAuthor = entry.authorName
            duration = entry.duration
            startTime = session.startTime
            currentTime = session.currentTime
            timeListening = Int(session.timeListening.rounded())
            startedAt = session.startedAt.millisecondsSince1970
            updatedAt = session.updatedAt.millisecondsSince1970
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: session.updatedAt)
            date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            dayOfWeek = days[((parts.weekday ?? 1) - 1) % 7]
        }

        enum CodingKeys: String, CodingKey {
            case id, libraryItemId, bookId, libraryId, mediaType, episodeId, displayTitle, displayAuthor, duration
            case playMethod, mediaPlayer, startTime, currentTime, timeListening, startedAt, updatedAt, date, dayOfWeek
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(libraryItemId, forKey: .libraryItemId)
            try container.encode(bookId, forKey: .bookId)
            try container.encode(libraryId, forKey: .libraryId)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encodeNil(forKey: .episodeId)
            try container.encode(displayTitle, forKey: .displayTitle)
            try container.encode(displayAuthor, forKey: .displayAuthor)
            try container.encode(duration, forKey: .duration)
            try container.encode(playMethod, forKey: .playMethod)
            try container.encode(mediaPlayer, forKey: .mediaPlayer)
            try container.encode(startTime, forKey: .startTime)
            try container.encode(currentTime, forKey: .currentTime)
            try container.encode(timeListening, forKey: .timeListening)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(date, forKey: .date)
            try container.encode(dayOfWeek, forKey: .dayOfWeek)
        }
    }

    let deviceInfo: DeviceInfo
    let sessions: [Session]
}

extension Responses {
    /// Reads `POST /api/session/local-all`: one result per session. `success: true` is delivered, whatever
    /// `progressSynced` says. A result that can't be read is left out (that session stays unsent).
    static func sessionResults(_ data: Data) throws(ServerAPIError) -> [SessionResult] {
        struct Result: Decodable {
            let id: String
            let success: Bool
            let error: String?
        }
        struct Lossy: Decodable {
            let result: Result?
            init(from decoder: any Decoder) throws {
                result = try? Result(from: decoder)
            }
        }
        struct Body: Decodable {
            let results: [Lossy]
        }
        do {
            return try JSONDecoder().decode(Body.self, from: data).results.compactMap(\.result).map {
                SessionResult(id: $0.id.lowercased(), isDelivered: $0.success, error: $0.error)
            }
        } catch {
            throw .unreadableResponse
        }
    }
}
