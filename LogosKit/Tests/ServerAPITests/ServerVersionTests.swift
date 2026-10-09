import ServerAPI
import Testing

@Suite("Minimum Server version")
struct ServerVersionTests {
    @Test(
        "Servers from 2.36 on are supported, older ones aren't",
        arguments: [
            ("2.37.1", true),
            ("2.36.0", true),
            ("2.36", true),
            ("3.0.0", true),
            ("2.100.0", true),
            ("2.35.9", false),
            ("2.9.0", false),
            ("1.40.0", false),
        ]
    )
    func gate(version: String, supported: Bool) throws {
        let parsed = try #require(ServerVersion(version))
        #expect(parsed.isSupported == supported)
    }

    @Test("A version that can't be read isn't a version", arguments: ["", "abc", "2.x.1", "v", "2..1"])
    func unreadable(version: String) {
        #expect(ServerVersion(version) == nil)
    }

    @Test("The version keeps the text the Server reported, for the Server too old message")
    func keepsText() throws {
        #expect(try #require(ServerVersion("2.35.1")).description == "2.35.1")
    }
}
