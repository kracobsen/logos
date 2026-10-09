import Foundation
import Testing

@testable import ServerAPI

@Suite("Requests for full Book data")
struct BookDataRequestTests {
    let server = URL(string: "https://abs.example.com")!

    @Test("A batch is an authenticated POST of the library item ids")
    func batch() throws {
        let request = Requests.bookDataBatch(["a", "b"], on: server, accessToken: "access-1")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/items/batch/get")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: [String]]
        #expect(body == ["libraryItemIds": ["a", "b"]])
    }

    @Test("One Book is an authenticated GET of the expanded item")
    func single() {
        let request = Requests.bookData("item-1", on: server, accessToken: "access-1")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/items/item-1?expanded=1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }
}
