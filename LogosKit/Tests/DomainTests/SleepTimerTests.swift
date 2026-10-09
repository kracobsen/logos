import Domain
import Testing

@Suite("The Sleep Timer's stop point")
struct SleepTimerTests {
    let chapters = ChapterList(
        [
            Chapter(id: 0, start: 0, end: 600, title: "One"),
            Chapter(id: 1, start: 600, end: 1500, title: "Two"),
            Chapter(id: 2, start: 1500, end: 2400, title: "Three"),
            Chapter(id: 3, start: 2400, end: 3600, title: "Four"),
        ], bookDuration: 3600, bookTitle: "Book")

    @Test("\"End of this Chapter\" stops at the end of the Chapter playing and resumes at the next one's start")
    func endOfThisChapter() throws {
        let timer = try #require(SleepTimer(chapters: 1, from: 900, in: chapters, bookDuration: 3600))

        #expect(timer.chapterNumber == 2)
        #expect(timer.stopAt == 1500)
        #expect(timer.resumeAt == 1500)
        #expect(!timer.endsBook)
    }

    @Test("Two or more Chapters count the Chapter playing as the first")
    func severalChapters() throws {
        let timer = try #require(SleepTimer(chapters: 3, from: 900, in: chapters, bookDuration: 3600))

        #expect(timer.chapterNumber == 4)
        #expect(timer.stopAt == 3600)
        #expect(timer.endsBook)
    }

    @Test("At a Chapter boundary the Chapter starting there is the one playing")
    func atBoundary() throws {
        let timer = try #require(SleepTimer(chapters: 1, from: 1500, in: chapters, bookDuration: 3600))

        #expect(timer.chapterNumber == 3)
        #expect(timer.stopAt == 2400)
    }

    @Test("More Chapters than the Book has left, or none, can't be set")
    func outOfRange() {
        #expect(SleepTimer(chapters: 4, from: 900, in: chapters, bookDuration: 3600) == nil)
        #expect(SleepTimer(chapters: 0, from: 900, in: chapters, bookDuration: 3600) == nil)
    }

    @Test("A Book with no Chapters is one Chapter, so the timer stops at the end of the Book")
    func noChapters() throws {
        let single = ChapterList([], bookDuration: 5000, bookTitle: "Book")

        let timer = try #require(SleepTimer(chapters: 1, from: 1234, in: single, bookDuration: 5000))

        #expect(timer.chapterNumber == 1)
        #expect(timer.stopAt == 5000)
        #expect(timer.resumeAt == 5000)
        #expect(timer.endsBook)
        #expect(SleepTimer(chapters: 2, from: 1234, in: single, bookDuration: 5000) == nil)
    }

    @Test("With a gap between Chapters it stops at the Chapter's end and resumes at the next Chapter's start")
    func gap() throws {
        let gapped = ChapterList(
            [
                Chapter(id: 0, start: 0, end: 590, title: "One"),
                Chapter(id: 1, start: 600, end: 1200, title: "Two"),
            ], bookDuration: 1200, bookTitle: "Book")

        let timer = try #require(SleepTimer(chapters: 1, from: 10, in: gapped, bookDuration: 1200))

        #expect(timer.stopAt == 590)
        #expect(timer.resumeAt == 600)
    }

    @Test("A last Chapter that ends before the Book does stops there, not at the end of the Book")
    func lastChapterShort() throws {
        let short = ChapterList(
            [Chapter(id: 0, start: 0, end: 1150, title: "One")], bookDuration: 1200, bookTitle: "Book")

        let timer = try #require(SleepTimer(chapters: 1, from: 10, in: short, bookDuration: 1200))

        #expect(timer.stopAt == 1150)
        #expect(timer.resumeAt == 1150)
        #expect(!timer.endsBook)
    }

    @Test("The picker offers every Chapter left, from \"End of this Chapter\" to the last")
    func options() {
        let options = SleepTimer.options(from: 900, in: chapters, bookDuration: 3600)

        #expect(options.map(\.chapterNumber) == [2, 3, 4])
        #expect(options.map(\.stopAt) == [1500, 2400, 3600])
    }

    @Test("+1 Chapter moves the stop to the end of the next Chapter, until there's none")
    func extended() throws {
        let timer = try #require(SleepTimer(chapters: 1, from: 900, in: chapters, bookDuration: 3600))

        let plusOne = try #require(timer.extended(in: chapters, bookDuration: 3600))

        #expect(plusOne.chapterNumber == 3)
        #expect(plusOne.stopAt == 2400)
        #expect(plusOne.resumeAt == 2400)
        let last = try #require(plusOne.extended(in: chapters, bookDuration: 3600))
        #expect(last.extended(in: chapters, bookDuration: 3600) == nil)
    }

    @Test("The projected time to the stop is wall-clock at the playing speed")
    func timeLeft() throws {
        let timer = try #require(SleepTimer(chapters: 2, from: 900, in: chapters, bookDuration: 3600))

        #expect(timer.timeLeft(from: 900, rate: 1) == 1500)
        #expect(timer.timeLeft(from: 900, rate: 2) == 750)
        #expect(timer.timeLeft(from: 3000, rate: 1) == 0)
    }
}
