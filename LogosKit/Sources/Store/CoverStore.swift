import Domain
import Foundation
import GRDB

/// A Book whose cover is behind (sync stage 3): its `coverVersion` differs from its `updatedAt`.
public struct CoverToFetch: Sendable, Hashable {
    public let bookID: String
    /// The Book's `updatedAt`: the version to record once the cover is fetched.
    public let version: Int64
    /// Whether the Server lists a cover. If not, there is nothing to fetch: any old file goes and the version is set.
    public let hasCover: Bool

    public init(bookID: String, version: Int64, hasCover: Bool) {
        self.bookID = bookID
        self.version = version
        self.hasCover = hasCover
    }
}

extension AppDatabase {
    /// The id of every Book in the Store.
    public func bookIDs() throws -> Set<String> {
        try pool.read { db in try Set(String.fetchAll(db, sql: "SELECT id FROM book")) }
    }

    /// The Books whose cover is behind, in no particular order.
    public func coversBehind() throws -> [CoverToFetch] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, updatedAt, hasCover FROM book WHERE coverVersion IS NOT updatedAt")
                .map { CoverToFetch(bookID: $0["id"], version: $0["updatedAt"], hasCover: $0["hasCover"]) }
        }
    }

    /// Records that the Book's cover file (or its absence) matches `version`. Does nothing if the Book is gone.
    public func setCoverVersion(_ version: Int64, forBook bookID: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE book SET coverVersion = ? WHERE id = ?", arguments: [version, bookID])
        }
    }

    /// The launch file check for covers: a Book whose cover file is missing goes back to behind, so the next sync
    /// fetches it again; a cover file whose Book is gone is deleted. Slow-ish (it lists the directory): run it in the
    /// background, after the first frame.
    public func checkCoverFiles(_ covers: CoverFiles) throws {
        let files = try covers.bookIDs()
        let orphans = try pool.write { db in
            let fetched = try Set(
                String.fetchAll(db, sql: "SELECT id FROM book WHERE hasCover AND coverVersion IS NOT NULL"))
            for bookID in fetched.subtracting(files) {
                try db.execute(sql: "UPDATE book SET coverVersion = NULL WHERE id = ?", arguments: [bookID])
            }
            let books = try Set(String.fetchAll(db, sql: "SELECT id FROM book"))
            return files.subtracting(books)
        }
        for bookID in orphans {
            covers.delete(forBook: bookID)
        }
    }

    /// The cover version of every Book that has a fetched cover, now and after each change. A changed version means
    /// a new file: drop any image decoded from the old one.
    public func coverVersionUpdates() -> AsyncThrowingStream<[String: Int64], any Error> {
        observe(Self.fetchCoverVersions)
    }

    /// The cover version of every Book that has a fetched cover.
    public func coverVersions() throws -> [String: Int64] {
        try pool.read(Self.fetchCoverVersions)
    }

    @Sendable static func fetchCoverVersions(_ db: Database) throws -> [String: Int64] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, coverVersion FROM book WHERE hasCover AND coverVersion IS NOT NULL")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["coverVersion"] as Int64) })
    }
}
