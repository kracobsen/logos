import Domain
import Testing

@testable import UI

@Suite("The Sleep Timer sheet")
@MainActor
struct SleepTimerPickerTests {
    /// Ten Chapters of 10 min each.
    let chapters = ChapterList(
        (0..<10).map { Chapter(id: $0, start: Double($0) * 600, end: Double($0 + 1) * 600, title: "C\($0 + 1)") },
        bookDuration: 6000, bookTitle: "Book")

    /// 35 min in: Chapter 4 (index 3) is playing.
    func picker(count: Int, at position: Double = 2100) -> SleepTimerPicker {
        SleepTimerPicker(count: count, position: position, chapters: chapters, bookDuration: 6000, rate: 1)
    }

    @Test("With no timer set it starts at End of this Chapter; a set timer reopens on its stop")
    func startingCount() throws {
        #expect(SleepTimerPicker.startingCount(for: nil, position: 2100, chapters: chapters) == 1)
        let timer = try #require(SleepTimer(chapters: 3, from: 2100, in: chapters, bookDuration: 6000))
        #expect(SleepTimerPicker.startingCount(for: timer, position: 2100, chapters: chapters) == 3)
    }

    @Test("The count runs from 1 to the last Chapter: − stops at 1, + at the last Chapter")
    func bounds() {
        let first = picker(count: 1)
        #expect(!first.canDecrease)
        #expect(first.canIncrease)
        #expect(first.stepped(by: -1) == 1)
        #expect(first.stepped(by: 1) == 2)

        let last = picker(count: 7)
        #expect(last.stopIndex == 9)
        #expect(last.canDecrease)
        #expect(!last.canIncrease)
        #expect(last.stepped(by: 1) == 7)

        #expect(picker(count: 12).count == 7)
        #expect(picker(count: 0).count == 1)
    }

    @Test("The strip shows the Chapters played, the one playing, those up to the stop, and those after it")
    func roles() {
        let picker = picker(count: 3)
        #expect(
            (0..<10).map(picker.role(of:)) == [
                .played, .played, .played, .playing, .toPlay, .toPlay, .afterStop, .afterStop, .afterStop, .afterStop,
            ])
        #expect(picker.stopIndex == 5)
    }

    @Test("Tapping a Chapter from the one playing on sets the stop there; an earlier one does nothing")
    func tapping() {
        let picker = picker(count: 3)
        #expect(picker.countStopping(at: 3) == 1)
        #expect(picker.countStopping(at: 9) == 7)
        #expect(picker.countStopping(at: 2) == nil)
        #expect(picker.countStopping(at: 0) == nil)
    }

    @Test("Under the strip: the stop Chapter's title and the projection; VoiceOver hears the count with it")
    func wording() {
        let picker = picker(count: 3)
        #expect(picker.stopTitle == "C6")
        #expect(picker.text.projection == "Stops at end of Chapter 6 · ~25 min")
        #expect(picker.accessibilityValue == "3 Chapters, Stops at end of Chapter 6 · ~25 min")
        #expect(self.picker(count: 1).accessibilityValue == "End of this Chapter, Stops at end of Chapter 4 · ~5 min")
    }

    @Test("A single-Chapter Book offers only End of this Chapter")
    func singleChapter() {
        let book = ChapterList([], bookDuration: 9 * 3600, bookTitle: "One Long Chapter")
        let picker = SleepTimerPicker(count: 1, position: 3600, chapters: book, bookDuration: 9 * 3600, rate: 1)
        #expect(!picker.canDecrease)
        #expect(!picker.canIncrease)
        #expect(picker.role(of: 0) == .playing)
        #expect(picker.stopTitle == "One Long Chapter")
        #expect(picker.text.title == "End of this Chapter")
        #expect(picker.text.projection == "Stops at end of Chapter 1 · ~8 h 0 min")
    }

    @Test("In the last Chapter only that Chapter can be chosen")
    func lastChapter() {
        let picker = picker(count: 3, at: 5700)
        #expect(picker.count == 1)
        #expect(!picker.canDecrease)
        #expect(!picker.canIncrease)
        #expect((0..<10).map(picker.role(of:)) == Array(repeating: .played, count: 9) + [.playing])
    }

    @Test("Near the end (Chapter 8 of 10), + stops at the last Chapter")
    func nearTheEnd() {
        let picker = picker(count: 2, at: 4300)
        #expect(picker.canIncrease)
        #expect(picker.stepped(by: 1) == 3)
        let last = self.picker(count: 3, at: 4300)
        #expect(last.stopTitle == "C10")
        #expect(!last.canIncrease)
    }
}
