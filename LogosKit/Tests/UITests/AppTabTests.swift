import Testing
import UI

@Suite("Tabs")
@MainActor
struct AppTabTests {
    @Test("the shell has four tabs in order: In Progress, Library, Series, Downloaded")
    func fourTabsInOrder() {
        #expect(AppTab.allCases.map(\.title) == ["In Progress", "Library", "Series", "Downloaded"])
    }
}
