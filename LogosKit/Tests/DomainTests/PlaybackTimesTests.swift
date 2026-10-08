import Domain
import Testing

@Suite("The player's times")
struct PlaybackTimesTests {
    let chapters = ChapterList(
        [
            Chapter(id: 0, start: 0, end: 600, title: "One"),
            Chapter(id: 1, start: 600, end: 1500, title: "Two"),
            Chapter(id: 2, start: 1500, end: 3600, title: "Three"),
        ], bookDuration: 3600, bookTitle: "Book")

    @Test("Elapsed and left are scoped to the Chapter the position is in; the Book line covers the whole Book")
    func scoped() {
        let times = PlaybackTimes(position: 900, chapters: chapters, bookDuration: 3600)

        #expect(times.chapter.title == "Two")
        #expect(times.chapterElapsed == 300)
        #expect(times.chapterLeft == 600)
        #expect(times.chapterFraction == 1.0 / 3.0)
        #expect(times.bookLeft == 2700)
        #expect(times.bookFraction == 0.25)
    }

    @Test("A position outside the Book is held to it")
    func clamped() {
        let past = PlaybackTimes(position: 4000, chapters: chapters, bookDuration: 3600)
        #expect(past.chapterLeft == 0)
        #expect(past.bookLeft == 0)
        #expect(past.bookFraction == 1)

        let empty = PlaybackTimes(position: 0, chapters: ChapterList([], bookDuration: 0, bookTitle: "B"), bookDuration: 0)
        #expect(empty.bookFraction == 0)
        #expect(empty.chapterFraction == 0)
    }
}
