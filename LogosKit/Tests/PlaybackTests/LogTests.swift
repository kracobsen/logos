import Domain
import Testing

@testable import Playback

@Suite("Playback logging")
struct LogTests {
    @Test("Playback logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .playback)
        #expect(logCategory.rawValue == "Playback")
    }
}
