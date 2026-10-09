import Domain
import Foundation
import GRDB

/// The reads behind the Library tab's sort, filter and search: every Book's progress, and every Series.
extension AppDatabase {
    /// Every stored progress, by Book id (including Books no longer in the Library).
    public func progressByBook() throws -> [String: BookProgress] {
        try pool.read(Self.fetchProgressByBook)
    }

    /// Every progress by Book id now, then again after each change.
    public func progressByBookUpdates() -> AsyncThrowingStream<[String: BookProgress], any Error> {
        observe(Self.fetchProgressByBook)
    }

    /// Every Series with a Book in the Library, in no particular order, each with its Books in reading order.
    public func librarySeries() throws -> [LibrarySeries] {
        try pool.read(Self.fetchLibrarySeries)
    }

    /// Every Series now, then again after each change.
    public func librarySeriesUpdates() -> AsyncThrowingStream<[LibrarySeries], any Error> {
        observe(Self.fetchLibrarySeries)
    }

    @Sendable static func fetchProgressByBook(_ db: Database) throws -> [String: BookProgress] {
        var byBook: [String: BookProgress] = [:]
        for record in try ProgressRecord.fetchAll(db) {
            byBook[record.bookID] = record.progress
        }
        return byBook
    }

    /// Reading order: by sequence as a number (`"2" < "2.5" < "10"`), Books without one last, then by title.
    @Sendable static func fetchLibrarySeries(_ db: Database) throws -> [LibrarySeries] {
        struct Member {
            let bookID: String
            let sortTitle: String
            let sequence: String?
        }
        var names: [String: String] = [:]
        var members: [String: [Member]] = [:]
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT bookSeries.seriesID, bookSeries.name, bookSeries.sequence, book.id, book.title
                FROM bookSeries JOIN book ON book.id = bookSeries.bookID
                """
        )
        while let row = try rows.next() {
            let seriesID: String = row["seriesID"]
            if names[seriesID] == nil { names[seriesID] = row["name"] }
            members[seriesID, default: []].append(
                Member(bookID: row["id"], sortTitle: TitleSort.sortTitle(row["title"]), sequence: row["sequence"]))
        }
        return members.map { seriesID, members in
            let ordered = members.sorted { a, b in
                switch (a.sequence, b.sequence) {
                case (let x?, let y?) where x != y:
                    return x.compare(y, options: .numeric) == .orderedAscending
                case (.some, nil): return true
                case (nil, .some): return false
                default: return TitleSort.areInIncreasingOrder(a.sortTitle, b.sortTitle)
                }
            }
            return LibrarySeries(id: seriesID, name: names[seriesID] ?? "", bookIDs: ordered.map(\.bookID))
        }
    }
}
