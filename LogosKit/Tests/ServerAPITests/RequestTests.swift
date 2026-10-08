import Foundation
import Testing

@testable import ServerAPI

@Suite("Requests the client sends")
struct RequestTests {
    let server = URL(string: "https://abs.example.com")!

    @Test("Status is an unauthenticated GET of /status")
    func status() {
        let request = Requests.status(server)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://abs.example.com/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A Server under a path keeps it")
    func subpath() {
        let request = Requests.status(URL(string: "https://example.com/audiobookshelf")!)
        #expect(request.url?.absoluteString == "https://example.com/audiobookshelf/status")
    }

    @Test("Login posts JSON credentials and asks for the tokens in the body")
    func logIn() throws {
        let request = Requests.logIn(server, username: "listener", password: "p\"ss wörd")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://abs.example.com/login")
        #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(json == ["username": "listener", "password": "p\"ss wörd"])
    }

    @Test("Refresh posts the refresh token in x-refresh-token, with no Authorization")
    func refresh() {
        let request = Requests.refresh(server, refreshToken: "refresh-1")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://abs.example.com/auth/refresh")
        #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Libraries is a GET with the bearer token")
    func libraries() {
        let request = Requests.libraries(server, accessToken: "access-1")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/libraries")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    @Test(
        "Status codes map to errors the callers act on",
        arguments: [
            (200, nil),
            (204, nil),
            (401, ServerAPIError.unauthorized),
            (429, ServerAPIError.rateLimited),
            (403, ServerAPIError.unexpectedStatus(403)),
            (500, ServerAPIError.unexpectedStatus(500)),
        ] as [(Int, ServerAPIError?)]
    )
    func statusCodes(code: Int, error: ServerAPIError?) {
        #expect(Responses.error(forStatusCode: code) == error)
    }
}
