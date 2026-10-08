import Domain
import Testing

@testable import UI

@Suite("The Sleep Timer control's wording")
@MainActor
struct SleepTimerMenuTests {
    let chapters = ChapterList(
        (0..<10).map { Chapter(id: $0, start: Double($0) * 600, end: Double($0 + 1) * 600, title: "C\($0)") },
        bookDuration: 6000, bookTitle: "Book")

    @Test("Each choice shows its Chapter count and the projected stop, in wall-clock time at the speed")
    func options() throws {
        let options = SleepTimer.options(from: 2100, in: chapters, bookDuration: 6000)

        let first = SleepTimerText(timer: options[0], position: 2100, chapters: chapters, rate: 1)
        #expect(first.title == "End of this Chapter")
        #expect(first.projection == "Stops at end of Chapter 4 · ~5 min")

        let third = SleepTimerText(timer: options[2], position: 2100, chapters: chapters, rate: 1)
        #expect(third.title == "3 Chapters")
        #expect(third.projection == "Stops at end of Chapter 6 · ~25 min")

        let fast = SleepTimerText(timer: options[6], position: 2100, chapters: chapters, rate: 2)
        #expect(fast.title == "7 Chapters")
        #expect(fast.projection == "Stops at end of Chapter 10 · ~33 min")

        let slow = SleepTimerText(timer: options[6], position: 2100, chapters: chapters, rate: 0.5)
        #expect(slow.projection == "Stops at end of Chapter 10 · ~2 h 10 min")
    }
}
