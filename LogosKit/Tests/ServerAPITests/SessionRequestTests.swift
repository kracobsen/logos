import Domain
import Foundation
import Testing

@testable import ServerAPI

@Suite("Listening sessions on the wire")
struct SessionRequestTests {
    let server = URL(string: "https://abs.example.com")!

    let entry = OutboxSession(
        session: ListeningSession(
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, bookID: "item-1", startTime: 100.5,
            currentTime: 460.25, timeListening: 179.6,
            startedAt: Date(millisecondsSince1970: 1_791_000_000_123),
            updatedAt: Date(millisecondsSince1970: 1_791_000_180_456), listenedUntil: .now, isPlaying: true,
            isOpen: true),
        revision: 4, mediaID: "media-1", title: "The First Light", authorName: "Ada Fixture", duration: 120)

    @Test("local-all posts the device and each session's latest state, with ms times and whole listening seconds")
    func body() throws {
        let device = ClientDevice(deviceID: "device-1", clientVersion: "1.0", model: "iPhone18,1", sdkVersion: "27.0")
        let request = Requests.syncSessions(
            [entry], device: device, libraryID: "lib-1", on: server, accessToken: "token-1",
            timeZone: TimeZone(identifier: "UTC")!)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/session/local-all")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let deviceInfo = try #require(json["deviceInfo"] as? [String: String])
        #expect(
            deviceInfo == [
                "deviceId": "device-1", "clientName": "Logos", "clientVersion": "1.0", "manufacturer": "Apple",
                "model": "iPhone18,1", "sdkVersion": "27.0",
            ])
        let sessions = try #require(json["sessions"] as? [[String: Any]])
        let session = try #require(sessions.first)
        #expect(session["id"] as? String == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(session["libraryItemId"] as? String == "item-1")
        #expect(session["bookId"] as? String == "media-1")
        #expect(session["libraryId"] as? String == "lib-1")
        #expect(session["mediaType"] as? String == "book")
        #expect(session["episodeId"] is NSNull)
        #expect(session["displayTitle"] as? String == "The First Light")
        #expect(session["displayAuthor"] as? String == "Ada Fixture")
        #expect(session["playMethod"] as? Int == 3)
        #expect(session["startTime"] as? Double == 100.5)
        #expect(session["currentTime"] as? Double == 460.25)
        #expect(session["timeListening"] as? Int == 180)
        #expect(session["startedAt"] as? Int64 == 1_791_000_000_123)
        #expect(session["updatedAt"] as? Int64 == 1_791_000_180_456)
        // 1_791_000_180 s is 2026-10-03 04:03 UTC, a Saturday.
        #expect(session["date"] as? String == "2026-10-03")
        #expect(session["dayOfWeek"] as? String == "Saturday")
    }

    @Test("Each result says whether that session was stored; progressSynced false still counts as stored")
    func results() throws {
        let data = Data(
            #"""
            {"results":[
              {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","success":true,"progressSynced":true},
              {"id":"b","success":true,"progressSynced":false},
              {"id":"c","success":false,"error":"Media item not found"},
              {"unexpected":1}
            ]}
            """#.utf8)

        #expect(
            try Responses.sessionResults(data) == [
                SessionResult(id: "6f9619ff-8b86-d011-b42d-00c04fc964ff", isDelivered: true),
                SessionResult(id: "b", isDelivered: true),
                SessionResult(id: "c", isDelivered: false, error: "Media item not found"),
            ])
    }

    @Test("A body that isn't a results list can't be read")
    func unreadable() {
        #expect(throws: ServerAPIError.unreadableResponse) { try Responses.sessionResults(Data("OK".utf8)) }
    }
}
