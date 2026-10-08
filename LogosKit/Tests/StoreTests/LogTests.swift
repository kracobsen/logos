import Domain
import Testing

@testable import Store

@Suite("Store logging")
struct LogTests {
    @Test("Store logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .store)
        #expect(logCategory.rawValue == "Store")
    }
}
