import Foundation
import Testing

@Suite("Integration harness")
struct HarnessTests {
    @Test(
        "The harness Server reports the pinned audiobookshelf version",
        .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
    )
    func statusReportsPinnedVersion() async throws {
        let server = try IntegrationServer.current()
        let (data, response) = try await server.session.data(from: server.baseURL.appending(path: "status"))

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let status = try JSONDecoder().decode(Status.self, from: data)
        #expect(status.serverVersion == "2.37.1")
        #expect(status.isInit)
        #expect(status.authMethods.contains("local"))
    }

    @Test(
        "The harness accepts only a loopback Server",
        arguments: [
            ("http://127.0.0.1:13378", true),
            ("http://localhost:13378", true),
            ("http://[::1]:13378", true),
            ("https://abs.example.com", false),
            ("http://192.168.1.10:13378", false),
            ("http://127.0.0.1.example.com", false),
            ("http://localhost.example.com:13378", false),
            ("not a url", false),
        ]
    )
    func acceptsOnlyLoopback(url: String, accepted: Bool) {
        let result = try? IntegrationServer.loopbackURL(url)
        #expect((result != nil) == accepted)
    }

    private struct Status: Decodable {
        let serverVersion: String
        let isInit: Bool
        let authMethods: [String]
    }
}
