import Domain
import Foundation
import GRDB

/// What the Downloads launch file check changed.
public struct DownloadFileCheck: Sendable, Hashable {
    /// Downloaded Books with a missing or wrong-size file: now not downloaded (and not queued again).
    public let lostBookIDs: Set<String>
    /// Not on Server Books among them, deleted entirely (as when their Download is removed): their covers can go.
    public let deletedBookIDs: Set<String>

    public init(lostBookIDs: Set<String>, deletedBookIDs: Set<String>) {
        self.lostBookIDs = lostBookIDs
        self.deletedBookIDs = deletedBookIDs
    }
}

extension AppDatabase {
    /// The Downloads launch file check (after a restore from backup, say, the files are gone but the database isn't):
    ///
    /// - A downloaded Book with a missing or wrong-size file becomes not downloaded, and isn't queued again; its
    ///   remaining files are deleted. A Not on Server one is deleted entirely.
    /// - A verified file of an unfinished Download that's missing or the wrong size is fetched again.
    /// - A Book folder without a Download is deleted.
    ///
    /// Reads the size of every file: run it in the background, after the first frame.
    public func checkDownloadFiles(_ files: DownloadFiles) throws -> DownloadFileCheck {
        let recorded = try pool.read { db in
            try DownloadFileRecord.filter(Column("isVerified")).fetchAll(db)
        }
        let damaged = recorded.filter { files.size(ofBook: $0.bookID, relPath: $0.relPath) != $0.size }
        let (lost, deleted, downloads) = try pool.write { db in
            var lost = Set<String>()
            var deleted = Set<String>()
            for file in damaged {
                let state = try String.fetchOne(
                    db, sql: "SELECT state FROM download WHERE bookID = ?", arguments: [file.bookID])
                if state == DownloadState.downloaded.rawValue {
                    guard lost.insert(file.bookID).inserted else { continue }
                    if try Self.discardDownload(db, bookID: file.bookID) {
                        deleted.insert(file.bookID)
                    }
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
            return (lost, deleted, downloads)
        }
        for file in damaged where !lost.contains(file.bookID) {
            files.delete(bookID: file.bookID, relPath: file.relPath)
        }
        for bookID in try files.bookIDs().subtracting(downloads) {
            files.deleteBook(bookID)
        }
        if !lost.isEmpty {
            log.notice("The launch file check found \(lost.count) Downloads with missing files")
        }
        return DownloadFileCheck(lostBookIDs: lost, deletedBookIDs: deleted)
    }
}
