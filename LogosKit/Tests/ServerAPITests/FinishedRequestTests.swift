import Domain
import Foundation
import Testing

@testable import ServerAPI

@Suite("Finished changes on the wire")
struct FinishedRequestTests {
    let server = URL(string: "https://abs.example.com")!
    let acted = Date(millisecondsSince1970: 1_791_000_000_123)

    func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Finished is a PATCH of the Book's progress with the end as currentTime, so the Server doesn't undo it")
    func finished() throws {
        let change = FinishedChange(bookID: "item-1", isFinished: true, position: 120, lastUpdate: acted)
        let request = Requests.updateFinished(change, duration: 120, on: server, accessToken: "token-1")

        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/me/progress/item-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(request)
        #expect(json["isFinished"] as? Bool == true)
        #expect(json["currentTime"] as? Double == 120)
        #expect(json["duration"] as? Double == 120)
        #expect(json["lastUpdate"] as? Int64 == 1_791_000_000_123)
        #expect(json["finishedAt"] as? Int64 == 1_791_000_000_123)
    }

    @Test("Cleared Finished sends position 0 and no finishedAt")
    func cleared() throws {
        let change = FinishedChange(bookID: "item-1", isFinished: false, position: 0, lastUpdate: acted)
        let json = try body(Requests.updateFinished(change, duration: 120, on: server, accessToken: "token-1"))

        #expect(json["isFinished"] as? Bool == false)
        #expect(json["currentTime"] as? Double == 0)
        #expect(json["lastUpdate"] as? Int64 == 1_791_000_000_123)
        #expect(json["finishedAt"] == nil)
    }
}
