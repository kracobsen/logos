import Domain
import Testing

@testable import Sync

@Suite("Sync logging")
struct LogTests {
    @Test("Sync logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .sync)
        #expect(logCategory.rawValue == "Sync")
    }
}
