import Domain
import Testing

@testable import UI

@Suite("The Sleep Timer's wording")
@MainActor
struct SleepTimerTextTests {
    let chapters = ChapterList(
        (0..<10).map { Chapter(id: $0, start: Double($0) * 600, end: Double($0 + 1) * 600, title: "C\($0)") },
        bookDuration: 6000, bookTitle: "Book")

    func timer(_ count: Int) throws -> SleepTimer {
        try #require(SleepTimer(chapters: count, from: 2100, in: chapters, bookDuration: 6000))
    }

    @Test("Each choice shows its Chapter count and the projected stop, in wall-clock time at the speed")
    func wording() throws {
        let first = SleepTimerText(timer: try timer(1), position: 2100, chapters: chapters, rate: 1)
        #expect(first.title == "End of this Chapter")
        #expect(first.projection == "Stops at end of Chapter 4 · ~5 min")

        let third = SleepTimerText(timer: try timer(3), position: 2100, chapters: chapters, rate: 1)
        #expect(third.title == "3 Chapters")
        #expect(third.projection == "Stops at end of Chapter 6 · ~25 min")

        let fast = SleepTimerText(timer: try timer(7), position: 2100, chapters: chapters, rate: 2)
        #expect(fast.title == "7 Chapters")
        #expect(fast.projection == "Stops at end of Chapter 10 · ~33 min")

        let slow = SleepTimerText(timer: try timer(7), position: 2100, chapters: chapters, rate: 0.5)
        #expect(slow.projection == "Stops at end of Chapter 10 · ~2 h 10 min")
    }
}
