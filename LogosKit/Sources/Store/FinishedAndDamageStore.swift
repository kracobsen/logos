import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// Sets or clears Finished by hand, as of `date` (when the listener acted). Finished puts the position at the
    /// end of the Book; clearing it puts the position at 0, so the Book doesn't count as Finished again at once.
    /// The Player does this itself for the Book it has loaded.
    public func setFinished(_ isFinished: Bool, ofBook bookID: String, at date: Date) throws {
        try pool.write { db in
            let duration =
                try Double.fetchOne(db, sql: "SELECT duration FROM book WHERE id = ?", arguments: [bookID]) ?? 0
            let progress = BookProgress(
                bookID: bookID, position: isFinished ? duration : 0,
                lastChanged: Date(millisecondsSince1970: date.millisecondsSince1970), isFinished: isFinished)
            try ProgressRecord(progress).upsert(db)
        }
    }

    /// Whether the Book is downloaded with every file on disk at its recorded size (the play-time check). Reads the
    /// size of each of the Book's files.
    public func hasIntactDownload(ofBook bookID: String, in files: DownloadFiles) throws -> Bool {
        let (state, recorded) = try pool.read { db in
            let state = try String.fetchOne(
                db, sql: "SELECT state FROM download WHERE bookID = ?", arguments: [bookID])
            let recorded = try DownloadFileRecord.filter(Column("bookID") == bookID).fetchAll(db)
            return (state, recorded)
        }
        guard state == DownloadState.downloaded.rawValue, !recorded.isEmpty else { return false }
        return recorded.allSatisfy { $0.isVerified && files.size(ofBook: bookID, relPath: $0.relPath) == $0.size }
    }

    /// A damaged Download (a file missing, the wrong size or failing to decode): the Book becomes not downloaded and
    /// its files are deleted. Unlike removing a Download, the Book and its progress stay even when it's Not on
    /// Server (it then offers only Remove Download), and nothing is queued again.
    public func discardDamagedDownload(ofBook bookID: String, files: DownloadFiles) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM download WHERE bookID = ?", arguments: [bookID])
        }
        files.deleteBook(bookID)
        log.notice("A damaged Download was discarded")
    }
}
