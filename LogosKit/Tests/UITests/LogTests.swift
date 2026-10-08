import Domain
import Testing

@testable import UI

@Suite("UI logging")
struct LogTests {
    @Test("UI logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .ui)
        #expect(logCategory.rawValue == "UI")
    }
}
