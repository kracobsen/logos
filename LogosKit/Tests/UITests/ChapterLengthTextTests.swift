import Testing

@testable import UI

@Suite("A Chapter's length in the Chapter lists")
@MainActor
struct ChapterLengthTextTests {
    @Test("Away from 1×, the wall-clock time at the speed follows in parentheses")
    func atSpeed() {
        #expect(BookDetailModel.chapterLength(600, speed: 1.5) == "10:00 (6:40)")
        #expect(BookDetailModel.chapterLength(3725, speed: 2) == "1:02:05 (31:03)")
        #expect(BookDetailModel.chapterLength(600, speed: 0.5) == "10:00 (20:00)")
    }

    @Test("At 1×, or where the speed doesn't change the time shown, it's the length alone")
    func atNormalSpeed() {
        #expect(BookDetailModel.chapterLength(600, speed: 1) == "10:00")
        #expect(BookDetailModel.chapterLength(0, speed: 2) == "0:00")
    }
}
