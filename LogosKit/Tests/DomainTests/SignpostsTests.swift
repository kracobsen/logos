import Domain
import Testing

@Suite("Signposts")
struct SignpostsTests {
    struct Boom: Error {}

    @Test("measuring a budgeted path returns the work's result")
    func measureReturnsResult() async {
        let result = await Signposts.measure(.tapBookToDetail) { 42 }
        #expect(result == 42)
    }

    @Test("measuring a budgeted path passes the work's error through")
    func measureRethrows() async {
        await #expect(throws: Boom.self) {
            try await Signposts.measure(.sortChange) { throw Boom() }
        }
    }

    @Test("measuring synchronous work on a budgeted path returns its result")
    func measureSyncReturnsResult() {
        let result = Signposts.measureSync(.letterIndexJump) { "A" }
        #expect(result == "A")
    }

    @Test("every budgeted path has a distinct signpost name")
    func distinctNames() {
        let names = BudgetedPath.allCases.map(\.signpostName)
        #expect(Set(names.map(String.init(describing:))).count == BudgetedPath.allCases.count)
    }
}
