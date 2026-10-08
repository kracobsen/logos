import Domain
import Testing

@testable import Downloads

@Suite("Downloads logging")
struct LogTests {
    @Test("Downloads logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .downloads)
        #expect(logCategory.rawValue == "Downloads")
    }
}
