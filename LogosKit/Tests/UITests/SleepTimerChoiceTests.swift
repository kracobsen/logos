import Domain
import Testing

@testable import UI

@Suite("The Sleep Timer sheet")
@MainActor
struct SleepTimerChoiceTests {
    /// Ten Chapters of 10 min each.
    let chapters = ChapterList(
        (0..<10).map { Chapter(id: $0, start: Double($0) * 600, end: Double($0 + 1) * 600, title: "C\($0 + 1)") },
        bookDuration: 6000, bookTitle: "Book")

    /// 35 min in: Chapter 4 (index 3) is playing.
    func choice(stop: Int, at position: Double = 2100) -> SleepTimerChoice {
        SleepTimerChoice(stopIndex: stop, position: position, chapters: chapters, bookDuration: 6000, rate: 1)
    }

    @Test("With no timer set it starts at End of this Chapter; a set timer reopens on its stop")
    func startingStop() throws {
        #expect(SleepTimerChoice.startingStop(for: nil, position: 2100, chapters: chapters) == 3)
        let timer = try #require(SleepTimer(chapters: 3, from: 2100, in: chapters, bookDuration: 6000))
        #expect(SleepTimerChoice.startingStop(for: timer, position: 2100, chapters: chapters) == 5)
        #expect(choice(stop: 5).count == 3)
    }

    @Test("The count runs from 1 to the last Chapter: − stops at 1, + at the last Chapter")
    func bounds() {
        let first = choice(stop: 3)
        #expect(first.count == 1)
        #expect(!first.canDecrease)
        #expect(first.canIncrease)
        #expect(first.stepped(by: -1) == 3)
        #expect(first.stepped(by: 1) == 4)

        let last = choice(stop: 9)
        #expect(last.count == 7)
        #expect(last.canDecrease)
        #expect(!last.canIncrease)
        #expect(last.stepped(by: 1) == 9)

        #expect(choice(stop: 12).stopIndex == 9)
        #expect(choice(stop: 1).stopIndex == 3)
    }

    @Test("If the next Chapter starts while the sheet is open, the stop stays on the same Chapter")
    func chapterChanges() {
        let later = choice(stop: 5, at: 2500)
        #expect(later.stopIndex == 5)
        #expect(later.count == 2)
        #expect(later.text.projection == "Stops at end of Chapter 6 · ~18 min")
        #expect(choice(stop: 3, at: 2500).stopIndex == 4)
    }

    @Test("The strip shows the Chapters played, the one playing, those up to the stop, and those after it")
    func roles() {
        let choice = choice(stop: 5)
        #expect(
            (0..<10).map(choice.role(of:)) == [
                .played, .played, .played, .playing, .toPlay, .toPlay, .afterStop, .afterStop, .afterStop, .afterStop,
            ])
    }

    @Test("Tapping a Chapter from the one playing on sets the stop there; an earlier one does nothing")
    func tapping() {
        let choice = choice(stop: 5)
        #expect(choice.stopIndex(tapping: 3) == 3)
        #expect(choice.stopIndex(tapping: 9) == 9)
        #expect(choice.stopIndex(tapping: 2) == nil)
        #expect(choice.stopIndex(tapping: 0) == nil)
    }

    @Test("Under the strip: the stop Chapter's title and the projection; VoiceOver hears the count with it")
    func wording() {
        let choice = choice(stop: 5)
        #expect(choice.stopTitle == "C6")
        #expect(choice.text.projection == "Stops at end of Chapter 6 · ~25 min")
        #expect(choice.accessibilityValue == "3 Chapters, Stops at end of Chapter 6 · ~25 min")
        #expect(self.choice(stop: 3).accessibilityValue == "End of this Chapter, Stops at end of Chapter 4 · ~5 min")
    }

    @Test("A single-Chapter Book offers only End of this Chapter")
    func singleChapter() {
        let book = ChapterList([], bookDuration: 9 * 3600, bookTitle: "One Long Chapter")
        let choice = SleepTimerChoice(stopIndex: 0, position: 3600, chapters: book, bookDuration: 9 * 3600, rate: 1)
        #expect(!choice.canDecrease)
        #expect(!choice.canIncrease)
        #expect(choice.role(of: 0) == .playing)
        #expect(choice.stopTitle == "One Long Chapter")
        #expect(choice.text.title == "End of this Chapter")
        #expect(choice.text.projection == "Stops at end of Chapter 1 · ~8 h 0 min")
    }

    @Test("In the last Chapter only that Chapter can be chosen")
    func lastChapter() {
        let choice = choice(stop: 5, at: 5700)
        #expect(choice.count == 1)
        #expect(choice.stopIndex == 9)
        #expect(!choice.canDecrease)
        #expect(!choice.canIncrease)
        #expect((0..<10).map(choice.role(of:)) == Array(repeating: .played, count: 9) + [.playing])
    }

    @Test("Near the end (Chapter 8 of 10), + stops at the last Chapter")
    func nearTheEnd() {
        let choice = choice(stop: 8, at: 4300)
        #expect(choice.canIncrease)
        #expect(choice.stepped(by: 1) == 9)
        let last = self.choice(stop: 9, at: 4300)
        #expect(last.stopTitle == "C10")
        #expect(!last.canIncrease)
    }
}
