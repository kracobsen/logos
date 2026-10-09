import Domain
import Foundation
import GRDB

/// Series, derived from the Books' stored Series membership (`bookSeries`, filled by sync stage 2). There are no
/// `/series` calls: a Series exists while at least one Book in the Store belongs to it.
extension AppDatabase {
    /// Every Series, A–Z.
    public func seriesList() throws -> [SeriesSummary] {
        try pool.read(Self.fetchSeriesList)
    }

    /// The Series list now, then again after each change.
    public func seriesListUpdates() -> AsyncThrowingStream<[SeriesSummary], any Error> {
        observe(Self.fetchSeriesList)
    }

    /// The Series with its Books in reading order, or `nil` if no Book in the Store belongs to it.
    public func seriesPage(id: String) throws -> SeriesPage? {
        try pool.read { db in try Self.fetchSeriesPage(db, id: id) }
    }

    /// The Series page now, then again after each change (membership, progress).
    public func seriesPageUpdates(id: String) -> AsyncThrowingStream<SeriesPage?, any Error> {
        observe { db in try Self.fetchSeriesPage(db, id: id) }
    }

    @Sendable static func fetchSeriesList(_ db: Database) throws -> [SeriesSummary] {
        // The name comes from the most recently updated Book (SQLite takes bare columns from the MAX row), in case
        // a rename has only reached some Books so far.
        try Row.fetchAll(
            db,
            sql: """
                SELECT bookSeries.seriesID, bookSeries.name, MAX(book.updatedAt),
                    COUNT(DISTINCT bookSeries.bookID) AS bookCount
                FROM bookSeries JOIN book ON book.id = bookSeries.bookID
                GROUP BY bookSeries.seriesID
                """
        )
        .map { SeriesSummary(id: $0["seriesID"], name: $0["name"], bookCount: $0["bookCount"]) }
        .sortedByName()
    }

    static func fetchSeriesPage(_ db: Database, id: String) throws -> SeriesPage? {
        // One row per Book (its first membership in this Series). Downloaded means a complete Download.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT book.id, book.title, book.publishedYear, bookSeries.name, bookSeries.sequence,
                    MIN(bookSeries.position), progress.position AS progressPosition, progress.isFinished,
                    IFNULL(download.state = 'downloaded', 0) AS isDownloaded
                FROM bookSeries
                JOIN book ON book.id = bookSeries.bookID
                LEFT JOIN progress ON progress.bookID = book.id
                LEFT JOIN download ON download.bookID = book.id
                WHERE bookSeries.seriesID = ?
                GROUP BY book.id
                ORDER BY book.updatedAt DESC
                """,
            arguments: [id])
        guard let first = rows.first else { return nil }
        let books = rows.map { row in
            SeriesBook(
                id: row["id"],
                title: row["title"],
                sequence: row["sequence"],
                publishedYear: row["publishedYear"],
                position: row["progressPosition"] ?? 0,
                isFinished: row["isFinished"] ?? false,
                isDownloaded: row["isDownloaded"]
            )
        }
        return SeriesPage(id: id, name: first["name"], books: books)
    }
}
