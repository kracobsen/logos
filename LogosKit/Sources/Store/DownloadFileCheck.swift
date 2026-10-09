import Domain
import Foundation
import GRDB

/// What the Downloads launch file check changed.
public struct DownloadFileCheck: Sendable, Hashable {
    /// Downloaded Books with a missing or wrong-size file: now not downloaded (and not queued again). The Books
    /// themselves stay, with their progress, Not on Server or not.
    public let lostBookIDs: Set<String>

    public init(lostBookIDs: Set<String>) {
        self.lostBookIDs = lostBookIDs
    }
}

extension AppDatabase {
    /// The Downloads launch file check (after a restore from backup, say, the files are gone but the database isn't):
    ///
    /// - A downloaded Book with a missing or wrong-size file becomes not downloaded, and isn't queued again; its
    ///   remaining files are deleted. Like a damaged Download found at play time, the Book keeps its progress and its
    ///   Not on Server flag (a Not on Server one then offers only Remove Download): local progress is never lost
    ///   because the files are.
    /// - A verified file of an unfinished Download that's missing or the wrong size is fetched again.
    /// - A Book folder without a Download is deleted.
    ///
    /// Reads the size of every file: run it in the background, after the first frame.
    public func checkDownloadFiles(_ files: DownloadFiles) throws -> DownloadFileCheck {
        let recorded = try pool.read { db in
            try DownloadFileRecord.filter(Column("isVerified")).fetchAll(db)
        }
        let damaged = recorded.filter { files.size(ofBook: $0.bookID, relPath: $0.relPath) != $0.size }
        let (lost, downloads) = try pool.write { db in
            var lost = Set<String>()
            for file in damaged {
                let state = try String.fetchOne(
                    db, sql: "SELECT state FROM download WHERE bookID = ?", arguments: [file.bookID])
                if state == DownloadState.downloaded.rawValue {
                    guard lost.insert(file.bookID).inserted else { continue }
                    try db.execute(sql: "DELETE FROM download WHERE bookID = ?", arguments: [file.bookID])
                } else if state != nil {
                    try db.execute(
                        sql: """
                            UPDATE downloadFile SET isVerified = 0, receivedBytes = 0, resumeData = NULL
                            WHERE bookID = ? AND relPath = ?
                            """,
                        arguments: [file.bookID, file.relPath])
                }
            }
            let downloads = try Set(String.fetchAll(db, sql: "SELECT bookID FROM download"))
            return (lost, downloads)
        }
        for file in damaged where !lost.contains(file.bookID) {
            files.delete(bookID: file.bookID, relPath: file.relPath)
        }
        for bookID in try files.bookIDs().subtracting(downloads) {
            files.deleteBook(bookID)
        }
        for bookID in lost.sorted() {
            log.notice("The launch file check found missing files in the Download of \(bookID, privacy: .public)")
        }
        return DownloadFileCheck(lostBookIDs: lost)
    }
}
