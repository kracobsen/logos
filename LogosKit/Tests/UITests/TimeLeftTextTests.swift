import Testing

@testable import UI

@Suite("A Book's time left on In Progress and Book detail")
@MainActor
struct TimeLeftTextTests {
    @Test("Away from 1×, the wall-clock time at the speed follows in parentheses")
    func atSpeed() {
        #expect(timeLeftText(3900, speed: 1.5) == "1 hr, 5 min left (43 min)")
        #expect(timeLeftText(1800, speed: 0.5) == "30 min left (1 hr)")
    }

    @Test("At 1×, or where the speed doesn't change the time shown, it's the time left alone")
    func atNormalSpeed() {
        #expect(timeLeftText(3900, speed: 1) == "1 hr, 5 min left")
        #expect(timeLeftText(10, speed: 1.05) == "0 min left")
    }
}
