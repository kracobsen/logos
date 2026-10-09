import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Book detail")
@MainActor
struct BookDetailModelTests {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let server: FakeServer
    let tokens = InMemoryTokenStore()
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase

    init() async throws {
        server = FakeServer(clock: clock)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        _ = try await SignIn(api: server, tokenStore: tokens, database: database)
            .signIn(address: "abs.example.com", username: "listener", password: "listenerpass")
    }

    func library() -> LibraryModel {
        let auth = Auth(server: server.address, api: server, tokenStore: tokens, clock: clock)
        return LibraryModel(
            database: database, sync: LibrarySync(database: database, api: server, auth: auth, clock: clock))
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func book(
        _ title: String = "The First Light",
        duration: Double = 120,
        size: Int64 = 480_462,
        description: String? = nil
    ) -> ListedBook {
        ListedBook(
            id: "first-light", mediaID: "media-1", title: title, subtitle: nil, authorName: "Ada Fixture",
            authorNameLF: "Fixture, Ada", narratorName: "Nell Narrator", seriesName: "Fixture Saga #1",
            description: description, publishedYear: "2001", genres: [], addedAt: Date(timeIntervalSince1970: 0),
            updatedAt: 1_700_000_000_000, duration: duration, size: size, hasCover: true)
    }

    let chapters = [
        Chapter(id: 0, start: 0, end: 40, title: "Dawn"),
        Chapter(id: 1, start: 40, end: 80, title: "Noon"),
        Chapter(id: 2, start: 80, end: 120, title: "Dusk"),
    ]

    @Test("The detail shows the stored Book straight away, with its Series and Chapters")
    func instant() throws {
        let book = book()
        try database.applyLibraryList([book], syncedAt: clock.now)
        try database.applyBookData([
            BookData(
                book: book, chapters: chapters, tracks: [],
                series: [
                    SeriesMembership(seriesID: "saga", name: "Fixture Saga", sequence: "1"),
                    SeriesMembership(seriesID: "other", name: "Other", sequence: nil),
                ])
        ])

        let model = library().detail(for: "first-light")

        #expect(model.detail?.title == "The First Light")
        #expect(model.detail?.authorName == "Ada Fixture")
        #expect(model.seriesLinks.map(\.label) == ["Fixture Saga #1", "Other"])
        #expect(model.chapters.map(\.title) == ["Dawn", "Noon", "Dusk"])
    }

    @Test(
        "The summary line is duration · Chapters · size",
        arguments: [
            (120.0, 3, Int64(480_462), "2 min · 3 Chapters · 480 KB"),
            (7_500, 1, 2_000_000_000, "2 h 5 min · 1 Chapter · 2 GB"),
            (3_600, 12, 52_000_000, "1 h 0 min · 12 Chapters · 52 MB"),
        ]
    )
    func summary(duration: Double, chapterCount: Int, size: Int64, expected: String) throws {
        let book = book(duration: duration, size: size)
        try database.applyLibraryList([book], syncedAt: clock.now)
        let chapters = (0..<chapterCount).map {
            Chapter(id: $0, start: Double($0), end: Double($0 + 1), title: "C\($0)")
        }
        try database.applyBookData([BookData(book: book, chapters: chapters, tracks: [], series: [])])

        #expect(library().detail(for: "first-light").summary == expected)
    }

    @Test("A Book with no Chapters is shown as one Chapter, named after the Book")
    func noChapters() throws {
        let book = book("Plain Silence")
        try database.applyLibraryList([book], syncedAt: clock.now)
        try database.applyBookData([BookData(book: book, chapters: [], tracks: [], series: [])])

        let model = library().detail(for: "first-light")

        #expect(model.chapters.map(\.title) == ["Plain Silence"])
        #expect(model.summary == "2 min · 1 Chapter · 480 KB")
    }

    @Test("The description is shown as plain text, paragraphs kept")
    func description() throws {
        let html = "<p>First &amp; <b>best</b>.</p><p>Second<br>line &#8212; &quot;quoted&quot;</p>"
        try database.applyLibraryList([book(description: html)], syncedAt: clock.now)

        #expect(library().detail(for: "first-light").descriptionText == "First & best.\n\nSecond\nline — \"quoted\"")
    }

    @Test("A detail opened before its data arrives fetches the Book right away and fills in")
    func fetchesWhenBehind() async throws {
        let book = book()
        server.books = [book]
        server.bookData = [BookData(book: book, chapters: chapters, tracks: [], series: [])]
        try database.applyLibraryList([book], syncedAt: clock.now)
        let model = library().detail(for: "first-light")
        #expect(model.chapters.count == 1)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        await model.fetchIfNeeded()
        await eventually { model.chapters.count == 3 }

        #expect(model.chapters.map(\.title) == ["Dawn", "Noon", "Dusk"])
        #expect(model.isFetching == false)
    }

    @Test("The detail shows how far the listener is in the Book")
    func progress() throws {
        try database.applyLibraryList([book(duration: 120)], syncedAt: clock.now)
        try database.saveProgress(
            BookProgress(bookID: "first-light", position: 30, lastChanged: clock.now, isFinished: false))

        #expect(library().detail(for: "first-light").progress.status == .inProgress(fraction: 0.25, remaining: 90))
    }

    @Test("A Book that isn't in the Store has no detail")
    func missing() {
        #expect(library().detail(for: "missing").detail == nil)
    }
}
