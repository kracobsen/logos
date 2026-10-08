import Domain
import Testing

@Suite("Chapters of a Book")
struct ChapterListTests {
    /// The First Light: Dawn 0–40, Noon 40–80, Dusk 80–120.
    let firstLight = ChapterList(
        [
            Chapter(id: 0, start: 0, end: 40, title: "Dawn"),
            Chapter(id: 1, start: 40, end: 80, title: "Noon"),
            Chapter(id: 2, start: 80, end: 120, title: "Dusk"),
        ],
        bookDuration: 120,
        bookTitle: "The First Light"
    )

    @Test(
        "A position falls in the Chapter whose range holds it; a boundary belongs to the Chapter it starts",
        arguments: [(0.0, "Dawn"), (39.99, "Dawn"), (40, "Noon"), (79.5, "Noon"), (80, "Dusk"), (119.9, "Dusk")]
    )
    func lookup(position: Double, title: String) {
        #expect(firstLight.chapter(at: position).title == title)
    }

    @Test("Before the start is the first Chapter; the end and beyond is the last")
    func outOfRange() {
        #expect(firstLight.index(at: -5) == 0)
        #expect(firstLight.index(at: 120) == 2)
        #expect(firstLight.index(at: 500) == 2)
    }

    @Test("A gap between Chapters belongs to the Chapter before it")
    func gap() {
        let chapters = ChapterList(
            [Chapter(id: 0, start: 0, end: 10, title: "A"), Chapter(id: 1, start: 20, end: 30, title: "B")],
            bookDuration: 30,
            bookTitle: "Gappy"
        )
        #expect(chapters.chapter(at: 15).title == "A")
        #expect(chapters.chapter(at: 20).title == "B")
    }

    @Test("Chapters are kept in Book order, however the Server sent them")
    func ordered() {
        let chapters = ChapterList(
            [Chapter(id: 1, start: 40, end: 80, title: "Second"), Chapter(id: 0, start: 0, end: 40, title: "First")],
            bookDuration: 80,
            bookTitle: "Shuffled"
        )
        #expect(chapters.chapters.map(\.title) == ["First", "Second"])
        #expect(chapters.chapter(at: 10).title == "First")
    }

    @Test("A Book with no Chapters is one Chapter spanning the whole Book, named after it")
    func noChapters() {
        let chapters = ChapterList([], bookDuration: 120, bookTitle: "Plain Silence")
        #expect(chapters.chapters == [Chapter(id: 0, start: 0, end: 120, title: "Plain Silence")])
        #expect(chapters.count == 1)
        #expect(chapters.chapter(at: 60).title == "Plain Silence")
    }

    @Test("A Chapter's duration is its length in seconds")
    func duration() {
        #expect(firstLight.chapters[1].duration == 40)
    }
}
