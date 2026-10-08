import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// Migration `v3-book-data`: stage 2's per-Book tables (Chapters, tracks, Series membership), each keyed by Book
    /// id and deleted with the Book.
    static func registerBookDataMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3-book-data") { db in
            // `position` is the order the Server gave.
            try db.create(table: "chapter") { table in
                table.column("bookID", .text).notNull().references("book", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("chapterID", .integer).notNull()
                table.column("start", .double).notNull()
                table.column("end", .double).notNull()
                table.column("title", .text).notNull()
                table.primaryKey(["bookID", "position"])
            }
            try db.create(table: "audioTrack") { table in
                table.column("bookID", .text).notNull().references("book", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("trackIndex", .integer).notNull()
                table.column("ino", .text).notNull()
                table.column("relPath", .text).notNull()
                table.column("size", .integer).notNull()
                table.column("duration", .double).notNull()
                table.column("startOffset", .double).notNull()
                table.column("mimeType", .text).notNull()
                table.primaryKey(["bookID", "position"])
            }
            try db.create(table: "bookSeries") { table in
                table.column("bookID", .text).notNull().references("book", onDelete: .cascade)
                table.column("position", .integer).notNull()
                table.column("seriesID", .text).notNull().indexed()
                table.column("name", .text).notNull()
                table.column("sequence", .text)
                table.primaryKey(["bookID", "position"])
            }
            // A Series rename doesn't bump the Book's updatedAt, but it does change the list's seriesName: treat
            // that as stage 2 being behind, so the stored Series names follow.
            try db.execute(
                sql: """
                    CREATE TRIGGER book_seriesNameChanged AFTER UPDATE OF seriesName ON book
                    WHEN OLD.seriesName IS NOT NEW.seriesName
                    BEGIN
                        UPDATE book SET fullDataVersion = NULL WHERE id = NEW.id;
                    END
                    """)
        }
    }

    /// The ids of the Books whose full data is behind their `updatedAt` (never fetched, or fetched at an older
    /// version): what stage 2 still has to fetch.
    public func booksBehindOnFullData() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT id FROM book WHERE fullDataVersion IS NOT updatedAt ORDER BY rowid")
        }
    }

    /// Stores fetched full Book data in one transaction: the list columns, Chapters, tracks and Series membership,
    /// and marks each Book's full data as current at the `updatedAt` it was fetched at.
    ///
    /// Data for a Book that's no longer in the Store is dropped (the list decides what exists), and so is data older
    /// than the Book's stored `updatedAt`.
    public func applyBookData(_ books: [BookData]) throws {
        try pool.write { db in
            for data in books {
                let book = data.book
                guard
                    let storedVersion = try Int64.fetchOne(
                        db, sql: "SELECT updatedAt FROM book WHERE id = ?", arguments: [book.id]),
                    book.updatedAt >= storedVersion
                else { continue }
                try ListedBookRecord(book).update(db)
                try db.execute(sql: "DELETE FROM chapter WHERE bookID = ?", arguments: [book.id])
                try db.execute(sql: "DELETE FROM audioTrack WHERE bookID = ?", arguments: [book.id])
                try db.execute(sql: "DELETE FROM bookSeries WHERE bookID = ?", arguments: [book.id])
                for (position, chapter) in data.chapters.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO chapter (bookID, position, chapterID, start, "end", title)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [book.id, position, chapter.id, chapter.start, chapter.end, chapter.title])
                }
                for (position, track) in data.tracks.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO audioTrack
                                (bookID, position, trackIndex, ino, relPath, size, duration, startOffset, mimeType)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            book.id, position, track.index, track.ino, track.relPath, track.size, track.duration,
                            track.startOffset, track.mimeType,
                        ])
                }
                for (position, series) in data.series.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO bookSeries (bookID, position, seriesID, name, sequence) VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [book.id, position, series.seriesID, series.name, series.sequence])
                }
                // After the list columns, so the Series-rename trigger can't undo it.
                try db.execute(
                    sql: "UPDATE book SET fullDataVersion = ? WHERE id = ?", arguments: [book.updatedAt, book.id])
            }
        }
    }

    /// The Book's detail, or `nil` if it isn't in the Store.
    public func bookDetail(id: String) throws -> BookDetail? {
        try pool.read { db in try Self.fetchBookDetail(db, id: id) }
    }

    /// The Book's detail now, then again after each change to it.
    public func bookDetailUpdates(id: String) -> AsyncThrowingStream<BookDetail?, any Error> {
        observe { db in try Self.fetchBookDetail(db, id: id) }
    }

    static func fetchBookDetail(_ db: Database, id: String) throws -> BookDetail? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, subtitle, authorName, narratorName, description, publishedYear, duration, size,
                        hasCover, updatedAt, fullDataVersion
                    FROM book WHERE id = ?
                    """,
                arguments: [id])
        else { return nil }
        let chapters = try Row.fetchAll(
            db, sql: #"SELECT chapterID, start, "end", title FROM chapter WHERE bookID = ? ORDER BY position"#,
            arguments: [id]
        ).map { Chapter(id: $0["chapterID"], start: $0["start"], end: $0["end"], title: $0["title"]) }
        let tracks = try Row.fetchAll(
            db,
            sql: """
                SELECT trackIndex, ino, relPath, size, duration, startOffset, mimeType
                FROM audioTrack WHERE bookID = ? ORDER BY position
                """,
            arguments: [id]
        ).map {
            AudioTrack(
                index: $0["trackIndex"], ino: $0["ino"], relPath: $0["relPath"], size: $0["size"],
                duration: $0["duration"], startOffset: $0["startOffset"], mimeType: $0["mimeType"])
        }
        let series = try Row.fetchAll(
            db, sql: "SELECT seriesID, name, sequence FROM bookSeries WHERE bookID = ? ORDER BY position",
            arguments: [id]
        ).map { SeriesMembership(seriesID: $0["seriesID"], name: $0["name"], sequence: $0["sequence"]) }
        let title: String = row["title"]
        let duration: Double = row["duration"]
        let fullDataVersion: Int64? = row["fullDataVersion"]
        let updatedAt: Int64 = row["updatedAt"]
        return BookDetail(
            id: id,
            title: title,
            subtitle: row["subtitle"],
            authorName: row["authorName"],
            narratorName: row["narratorName"],
            description: row["description"],
            publishedYear: row["publishedYear"],
            duration: duration,
            size: row["size"],
            hasCover: row["hasCover"],
            series: series,
            chapters: ChapterList(chapters, bookDuration: duration, bookTitle: title),
            tracks: tracks,
            hasCurrentFullData: fullDataVersion == updatedAt
        )
    }
}
