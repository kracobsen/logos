import Domain
import Foundation
import Testing

@Suite("The generated fixture Library")
struct FixtureLibraryTests {
    let library = FixtureLibrary(bookCount: 3000)

    @Test("It has the asked-for number of Books, each with its own id")
    func count() {
        #expect(library.books.count == 3000)
        #expect(Set(library.books.map(\.book.id)).count == 3000)
    }

    @Test("It's the same every time")
    func deterministic() {
        #expect(FixtureLibrary(bookCount: 3000) == library)
    }

    @Test("Titles fill every section of the letter index")
    func everyLetter() {
        let letters = Set(library.books.map { TitleSort.indexLetter(TitleSort.sortTitle($0.book.title)) })
        let expected = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init) + [TitleSort.otherLetter])
        #expect(letters == expected)
    }

    @Test("About a third of the Books are in Series, numbered from 1, each Series by one author")
    func series() throws {
        let members = library.books.filter { !$0.series.isEmpty }
        #expect(members.count > 700 && members.count < 1500)
        let bySeries = Dictionary(grouping: members) { $0.series[0].seriesID }
        #expect(bySeries.count > 150)
        for books in bySeries.values {
            #expect(Set(books.map(\.book.authorName)).count == 1)
            let first = try #require(books.first?.series.first)
            #expect(first.sequence == "1")
            #expect(books[0].book.seriesName == "\(first.name) #1")
        }
    }

    @Test("Most Books have a cover, and authors have several Books")
    func coversAndAuthors() {
        let covered = library.books.filter(\.book.hasCover).count
        #expect(covered > 2500 && covered < 3000)
        #expect(Set(library.books.map(\.book.authorName)).count > 600)
    }

    @Test("Downloaded Books are short, their files back to back, and the first is the last one listened to")
    func downloaded() throws {
        #expect(library.downloadedBookIDs.count == 3)
        for id in library.downloadedBookIDs {
            let data = try #require(library.books.first { $0.book.id == id })
            #expect(data.tracks.map(\.startOffset) == [0, 120])
            #expect(data.book.duration == 240)
            #expect(data.chapters.last?.end == 240)
            #expect(library.progress.contains { $0.bookID == id && !$0.isFinished })
        }
        let lastPlayed = library.progress.max { $0.lastUpdate < $1.lastUpdate }
        #expect(lastPlayed?.bookID == library.downloadedBookIDs.first)
    }

    @Test("Some Books are in progress and some Finished, all within their Books")
    func progress() throws {
        let durations = Dictionary(uniqueKeysWithValues: library.books.map { ($0.book.id, $0.book.duration) })
        let finished = library.progress.filter(\.isFinished)
        let started = library.progress.filter { !$0.isFinished }
        #expect(finished.count > 100 && finished.count < 300)
        #expect(started.count > 250 && started.count < 500)
        for record in library.progress {
            let duration = try #require(durations[record.bookID])
            #expect(record.position <= duration)
        }
    }

    @Test("A small Library still works")
    func small() {
        let small = FixtureLibrary(bookCount: 5, downloadedCount: 2)
        #expect(small.books.count == 5)
        #expect(small.downloadedBookIDs.count == 2)
    }
}
