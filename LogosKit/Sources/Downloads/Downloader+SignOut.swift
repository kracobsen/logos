import Domain
import Foundation
import ServerAPI
import Store

extension Downloader {
    /// Signing out: every transfer and backoff stops, and every Download's files (partial ones included) are
    /// deleted. From then on this Downloads starts and handles nothing; a new sign-in builds a new one. The database
    /// rows go with the sign-out wipe.
    public func signOut() async {
        isSignedOut = true
        for task in backingOff.values { task.cancel() }
        backingOff = [:]
        for bookID in Set(await transfers.running().map(\.bookID)) {
            await transfers.cancel(bookID: bookID)
        }
        files.deleteAll()
        log.notice("Signed out: transfers cancelled and Downloads deleted")
    }
}
