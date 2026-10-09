import Domain
import Foundation
import Testing

@Suite("Library sort, filter and search")
struct LibraryCatalogTests {
    func row(
        _ title: String,
        id: String? = nil,
        author: String = "",
        authorLF: String? = nil,
        narrator: String = "",
        series: String = "",
        added: TimeInterval = 0
    ) -> LibraryRow {
        LibraryRow(
            id: id ?? title,
            title: title,
            authorName: author,
            authorNameLF: authorLF ?? author,
            narratorName: narrator,
            seriesName: series,
            addedAt: Date(timeIntervalSince1970: added),
            duration: 0
        )
    }

    func titles(_ results: LibraryResults) -> [String] {
        results.sections.flatMap(\.rows).map(\.title)
    }

    @Test(
        "Search matches a fragment of the title, author, narrator or Series name, ignoring case and diacritics",
        arguments: [
            ("first", true), ("FIRST LIGHT", true), ("ada", true), ("nell narr", true), ("saga #1", true),
            ("fixture saga", true), ("eclair", true), ("ÉCLAIR", true), ("Éclair", true), ("dark", false),
            ("ada nell", false),
        ]
    )
    func searchFolding(query: String, matches: Bool) {
        let catalog = LibraryCatalog(
            rows: [
                row(
                    "The First Light", author: "Ada Fixture", narrator: "Nell Narrator", series: "Fixture Saga #1"),
                row("Éclairs at Dawn"),
            ],
            series: []
        )
        let results = catalog.results(LibraryQuery(search: query), progress: [:])
        #expect(!results.sections.isEmpty == matches)
    }

    func progress(_ id: String, at position: TimeInterval = 10, ago minutes: Double, finished: Bool = false)
        -> (String, BookProgress)
    {
        (
            id,
            BookProgress(
                bookID: id, position: position,
                lastChanged: Date(timeIntervalSince1970: 1_000_000 - minutes * 60), isFinished: finished)
        )
    }

    @Test("Title order is A–Z ignoring a leading article, sectioned by letter with the index shown")
    func titleSort() {
        let catalog = LibraryCatalog(rows: [row("Zed"), row("The Apple"), row("Avocado"), row("3 Body")], series: [])
        let results = catalog.results(LibraryQuery(sort: .title), progress: [:])
        #expect(results.sections.map(\.letter) == ["#", "A", "Z"])
        #expect(titles(results) == ["3 Body", "The Apple", "Avocado", "Zed"])
        #expect(results.showsIndex)
    }

    @Test(
        "Author order is by Last, First, ignoring case and diacritics, then by title, sectioned by the author's letter")
    func authorSort() {
        let catalog = LibraryCatalog(
            rows: [
                row("Beta", author: "Zoe Adams", authorLF: "Adams, Zoe"),
                row("Gamma", author: "Émile Zola", authorLF: "Zola, Émile"),
                row("Alpha", author: "Zoe Adams", authorLF: "Adams, Zoe"),
                row("Delta", author: "ben brown", authorLF: "brown, ben"),
                row("Epsilon", author: "Ann Böll", authorLF: "Böll, Ann"),
            ],
            series: []
        )
        let results = catalog.results(LibraryQuery(sort: .author), progress: [:])
        #expect(titles(results) == ["Alpha", "Beta", "Epsilon", "Delta", "Gamma"])
        #expect(results.sections.map(\.letter) == ["A", "B", "Z"])
        #expect(results.showsIndex)
    }

    @Test("Recently added puts the newest first, in one section without an index")
    func recentlyAddedSort() {
        let catalog = LibraryCatalog(
            rows: [row("Old", added: 100), row("Newest", added: 300), row("Middle", added: 200)], series: [])
        let results = catalog.results(LibraryQuery(sort: .recentlyAdded), progress: [:])
        #expect(titles(results) == ["Newest", "Middle", "Old"])
        #expect(results.sections.count == 1)
        #expect(!results.showsIndex)
    }

    @Test("Recently listened puts the most recently listened first, then the never-listened in Title order")
    func recentlyListenedSort() {
        let catalog = LibraryCatalog(
            rows: [row("Unheard B"), row("Long ago"), row("Unheard A"), row("Just now"), row("Done")], series: [])
        let progress = Dictionary(
            uniqueKeysWithValues: [
                progress("Long ago", ago: 600), progress("Just now", ago: 1),
                progress("Done", at: 0, ago: 60, finished: true),
            ])
        let results = catalog.results(LibraryQuery(sort: .recentlyListened), progress: progress)
        #expect(titles(results) == ["Just now", "Done", "Long ago", "Unheard A", "Unheard B"])
        #expect(!results.showsIndex)
    }

    @Test(
        "Filters narrow the rows by progress",
        arguments: [
            (LibraryFilter.all, ["Finished", "Halfway", "Never", "Reset"]),
            (.notStarted, ["Never", "Reset"]),
            (.inProgress, ["Halfway"]),
            (.finished, ["Finished"]),
        ]
    )
    func filters(filter: LibraryFilter, expected: [String]) {
        let catalog = LibraryCatalog(rows: [row("Never"), row("Halfway"), row("Finished"), row("Reset")], series: [])
        let progress = Dictionary(
            uniqueKeysWithValues: [
                progress("Halfway", at: 300, ago: 5), progress("Finished", at: 0, ago: 10, finished: true),
                progress("Reset", at: 0, ago: 1),
            ])
        #expect(titles(catalog.results(LibraryQuery(filter: filter), progress: progress)) == expected)
    }

    var sagaCatalog: LibraryCatalog {
        LibraryCatalog(
            rows: [
                row("Second Dawn", id: "b2", author: "Ada Fixture", series: "Fixture Saga #2", added: 2),
                row("The First Light", id: "b1", author: "Ada Fixture", series: "Fixture Saga #1", added: 1),
                row("Plain Silence", id: "p", author: "Ben Example", added: 3),
                row("Sagas of Old", id: "o", author: "Cy Other", added: 4),
            ],
            series: [
                LibrarySeries(id: "s1", name: "Fixture Saga", bookIDs: ["b1", "b2"]),
                LibrarySeries(id: "s2", name: "Ben's Sagas", bookIDs: ["p"]),
                LibrarySeries(id: "s3", name: "Unrelated", bookIDs: ["o"]),
            ]
        )
    }

    @Test("Search shows matching Series above matching Books, in the current sort, without the letter index")
    func searchWithSeries() {
        let results = sagaCatalog.results(LibraryQuery(sort: .recentlyAdded, search: "SAGA"), progress: [:])
        #expect(results.series.map(\.name) == ["Ben's Sagas", "Fixture Saga"])
        #expect(titles(results) == ["Sagas of Old", "Second Dawn", "The First Light"])
        #expect(!results.showsIndex)

        let byTitle = sagaCatalog.results(LibraryQuery(sort: .title, search: "saga"), progress: [:])
        #expect(titles(byTitle) == ["The First Light", "Sagas of Old", "Second Dawn"])
        #expect(byTitle.sections.count == 1)
        #expect(!byTitle.showsIndex)
    }

    @Test("Search respects the filter: Books outside it and Series with none of their Books in it are left out")
    func searchRespectsFilter() {
        let progress = Dictionary(uniqueKeysWithValues: [progress("b2", ago: 5)])
        let results = sagaCatalog.results(LibraryQuery(filter: .inProgress, search: "saga"), progress: progress)
        #expect(results.series.map(\.name) == ["Fixture Saga"])
        #expect(titles(results) == ["Second Dawn"])
    }

    @Test("A blank search is no search: Series stay out and the index shows")
    func blankSearch() {
        let results = sagaCatalog.results(LibraryQuery(search: "   "), progress: [:])
        #expect(results.series.isEmpty)
        #expect(results.rowCount == 4)
        #expect(results.showsIndex)
    }
}
