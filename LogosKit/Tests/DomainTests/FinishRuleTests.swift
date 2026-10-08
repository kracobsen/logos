import Domain
import Testing

@Suite("The Finished 30 s rule")
struct FinishRuleTests {
    @Test("Leaving a Book within its last 30 s finishes it", arguments: [3570.0, 3585, 3599.5, 3600])
    func withinLast30Seconds(position: Double) {
        #expect(FinishRule.finishes(at: position, duration: 3600))
    }

    @Test("Leaving it earlier doesn't", arguments: [0.0, 1800, 3569.9])
    func earlier(position: Double) {
        #expect(!FinishRule.finishes(at: position, duration: 3600))
    }

    @Test("A Book shorter than 30 s finishes wherever it's left")
    func shortBook() {
        #expect(FinishRule.finishes(at: 5, duration: 20))
    }

    @Test("A Book of unknown length (0) never finishes by the rule")
    func unknownDuration() {
        #expect(!FinishRule.finishes(at: 0, duration: 0))
        #expect(!FinishRule.finishes(at: 10, duration: 0))
    }
}
