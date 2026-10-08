import Domain
import Testing

@testable import ServerAPI

@Suite("ServerAPI logging")
struct LogTests {
    @Test("ServerAPI logs under its own category")
    func logsUnderItsOwnCategory() {
        #expect(logCategory == .serverAPI)
        #expect(logCategory.rawValue == "ServerAPI")
    }
}
