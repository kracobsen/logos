import Domain
import Foundation
import Store

extension Downloader {
    /// Reorders the queue: the queued Books in `bookIDs` take the queued places in that order. The active Book keeps
    /// downloading; the reordered ones start after it.
    public func reorder(_ bookIDs: [String]) {
        do {
            try database.reorderQueuedDownloads(bookIDs)
        } catch {
            log.error("Couldn't reorder the Download queue: \(String(describing: error), privacy: .public)")
        }
    }

    /// The launch file check: a downloaded Book with a missing (or wrong-size) file becomes not downloaded and isn't
    /// queued again (a Not on Server one goes entirely); folders left without a Download are deleted. Run it in the
    /// background after the first frame, before ``resume()``.
    public func checkFiles() {
        do {
            let check = try database.checkDownloadFiles(files)
            for bookID in check.deletedBookIDs {
                covers?.delete(forBook: bookID)
            }
        } catch {
            log.error("The Downloads file check failed: \(String(describing: error), privacy: .public)")
        }
    }
}
