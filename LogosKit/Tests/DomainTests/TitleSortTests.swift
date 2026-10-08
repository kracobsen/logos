import Domain
import Foundation
import Testing

@Suite("Title sorting")
struct TitleSortTests {
    func row(_ title: String, id: String? = nil) -> LibraryRow {
        LibraryRow(
            id: id ?? title,
            title: title,
            authorName: "",
            narratorName: "",
            seriesName: "",
            addedAt: Date(timeIntervalSince1970: 0),
            duration: 0
        )
    }

    func titles(_ titles: [String]) -> [String] {
        titles.map { row($0) }.sortedByTitle().map(\.title)
    }

    @Test("Titles sort A–Z, ignoring a leading The, A or An")
    func ignoresArticles() {
        #expect(
            titles(["The Long Dark", "Second Dawn", "Between Lights", "An Owl", "A Zebra", "The First Light"])
                == ["Between Lights", "The First Light", "The Long Dark", "An Owl", "Second Dawn", "A Zebra"]
        )
    }

    @Test("Articles count only as whole leading words, in any case")
    func wholeWordsOnly() {
        #expect(
            titles(["Theory", "the Basics", "Anvil", "Apple", "THE Cat"]) == [
                "Anvil", "Apple", "the Basics", "THE Cat", "Theory",
            ])
    }

    @Test("A title that is only an article keeps it")
    func onlyAnArticle() {
        #expect(titles(["The", "Banana", "A"]) == ["A", "Banana", "The"])
    }

    @Test("Case and diacritics don't split the order, and numbers sort by value")
    func caseDiacriticsNumbers() {
        #expect(
            titles(["émile", "Eagle", "Ezra", "10 Lessons", "2 Towers"]) == [
                "2 Towers", "10 Lessons", "Eagle", "émile", "Ezra",
            ])
    }

    @Test("Equal titles keep a stable order by id")
    func stableTies() {
        let rows = [row("Same", id: "b"), row("Same", id: "a")]
        #expect(rows.sortedByTitle().map(\.id) == ["a", "b"])
    }

    @Test(
        "The letter index uses the first letter after the article, folded to A–Z, or # otherwise",
        arguments: [
            ("The Long Dark", "L"),
            ("an owl", "O"),
            ("Émile", "E"),
            ("2 Towers", "#"),
            ("“Quoted”", "#"),
            ("日本", "#"),
            ("", "#"),
        ]
    )
    func indexLetter(title: String, letter: String) {
        #expect(row(title).indexLetter == letter)
    }

    @Test("Sections group sorted rows by index letter, with every non-letter title under # first")
    func sections() {
        let sections = [row("Zed"), row("The Apple"), row("日本"), row("Avocado"), row("3 Body")].sectionedByTitle()
        #expect(sections.map(\.letter) == ["#", "A", "Z"])
        #expect(sections.map { $0.rows.map(\.title) } == [["3 Body", "日本"], ["The Apple", "Avocado"], ["Zed"]])
    }
}
