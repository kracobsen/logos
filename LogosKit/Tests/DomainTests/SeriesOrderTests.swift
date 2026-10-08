import Domain
import Testing

@Suite("Series reading order")
struct SeriesOrderTests {
    func book(_ id: String, sequence: String?, year: String? = nil, title: String? = nil) -> SeriesBook {
        SeriesBook(
            id: id, title: title ?? id, sequence: sequence, publishedYear: year, position: 0, isFinished: false,
            isDownloaded: false)
    }

    @Test("Sequences are read as decimals, not text: 2 before 10, 1.5 between 1 and 2")
    func decimal() {
        let books = [
            book("ten", sequence: "10"), book("two", sequence: "2"), book("one-and-a-half", sequence: "1.5"),
            book("one", sequence: "1"), book("zero-point-five", sequence: "0.5"),
        ]
        #expect(books.inReadingOrder().map(\.id) == ["zero-point-five", "one", "one-and-a-half", "two", "ten"])
    }

    @Test("Equal numbers in different spellings tie (1, 1.0, 01) and fall back to year, then title")
    func equalSequences() {
        let books = [
            book("c", sequence: "1.0", year: "2001", title: "C"), book("b", sequence: "01", year: "2000", title: "B"),
            book("a", sequence: "1", year: "2001", title: "A"),
        ]
        #expect(books.inReadingOrder().map(\.id) == ["b", "a", "c"])
    }

    @Test("Missing, empty and non-numeric sequences go last, by published year then title")
    func unnumberedLast() {
        let books = [
            book("loose-1999", sequence: nil, year: "1999", title: "Zebra"),
            book("text", sequence: "1a", year: "2005", title: "Apple"),
            book("empty", sequence: "", year: "1999", title: "Mango"),
            book("no-year", sequence: "  ", year: nil, title: "Aardvark"),
            book("three", sequence: "3", year: "2020"),
            book("roman", sequence: "IV", year: "1990", title: "Roman"),
        ]
        #expect(
            books.inReadingOrder().map(\.id) == ["three", "roman", "empty", "loose-1999", "text", "no-year"])
    }

    @Test("Things that only look numeric to a lenient parser count as non-numeric")
    func strictNumbers() {
        for sequence in ["nan", "inf", "1e3", "0x10", "1,5", "1.", ".5", "+-1", "1 2"] {
            #expect(SeriesOrder.number(sequence) == nil, "\(sequence)")
        }
        #expect(SeriesOrder.number(" 2.50 ") == SeriesOrder.number("2.5"))
        #expect(SeriesOrder.number("12") != nil)
    }

    @Test("The sequence is kept exactly as the Server gave it")
    func verbatim() {
        let books = [book("x", sequence: "01.50")]
        #expect(books.inReadingOrder().first?.sequence == "01.50")
    }
}

@Suite("Series Continue target")
struct SeriesContinueTests {
    typealias State = (position: Double, finished: Bool)

    /// Books 1, 2, 3 … in order, with the given progress.
    func series(_ states: [State], downloaded: Set<Int> = []) -> [SeriesBook] {
        states.enumerated().map { index, state in
            SeriesBook(
                id: "b\(index + 1)", title: "Book \(index + 1)", sequence: "\(index + 1)", publishedYear: nil,
                position: state.position, isFinished: state.finished, isDownloaded: downloaded.contains(index + 1))
        }
    }

    let fresh: State = (0, false)
    let started: State = (30, false)
    let done: State = (0, true)

    @Test("Nothing started: the first Book")
    func nothingStarted() {
        #expect(SeriesContinue.target(in: series([fresh, fresh, fresh]))?.book.id == "b1")
    }

    @Test("After finishing Book 1: Book 2")
    func afterFinished() {
        #expect(SeriesContinue.target(in: series([done, fresh, fresh]))?.book.id == "b2")
    }

    @Test("Partway through Book 2: Book 2 itself")
    func midBook() {
        #expect(SeriesContinue.target(in: series([done, started, fresh]))?.book.id == "b2")
    }

    @Test("The furthest-along started Book counts, not earlier gaps")
    func furthestAlong() {
        #expect(SeriesContinue.target(in: series([fresh, fresh, done, fresh]))?.book.id == "b4")
        #expect(SeriesContinue.target(in: series([started, fresh, done, fresh]))?.book.id == "b4")
    }

    @Test("Finished Books after the furthest started one are skipped")
    func skipsFinished() {
        #expect(SeriesContinue.target(in: series([started, done, fresh]))?.book.id == "b3")
        #expect(SeriesContinue.target(in: series([done, done, done, fresh]))?.book.id == "b4")
    }

    @Test("Everything from the furthest started Book on is Finished: no target")
    func none() {
        #expect(SeriesContinue.target(in: series([done, done])) == nil)
        #expect(SeriesContinue.target(in: series([fresh, done])) == nil)
        #expect(SeriesContinue.target(in: []) == nil)
    }

    @Test("It follows reading order, not the order given")
    func usesReadingOrder() {
        let books = Array(series([done, fresh, fresh]).reversed())
        #expect(SeriesContinue.target(in: books)?.book.id == "b2")
    }

    @Test("The button: Continue with Book N when downloaded, else Download Book N to continue")
    func label() throws {
        let downloaded = try #require(SeriesContinue.target(in: series([done, fresh], downloaded: [2])))
        #expect(downloaded.label == "Continue with Book 2")
        #expect(downloaded.action == .play)
        let notDownloaded = try #require(SeriesContinue.target(in: series([done, fresh])))
        #expect(notDownloaded.label == "Download Book 2 to continue")
        #expect(notDownloaded.action == .download)
    }

    @Test("Book N is the sequence as given, or the title when the Book has no number")
    func labelNumber() {
        let interlude = SeriesBook(
            id: "x", title: "Interlude", sequence: nil, publishedYear: nil, position: 0, isFinished: false,
            isDownloaded: true)
        let numbered = SeriesBook(
            id: "y", title: "Y", sequence: "1.50", publishedYear: nil, position: 0, isFinished: false,
            isDownloaded: true)
        #expect(SeriesContinue.target(in: [interlude, numbered])?.label == "Continue with Book 1.50")
        #expect(SeriesContinue.target(in: [interlude])?.label == "Continue with Interlude")
    }
}
