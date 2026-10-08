import Domain
import Foundation
import ServerAPI
import Store

/// Stage 2: full Book data (description, Chapters, tracks, Series membership).
extension LibrarySync {
    /// How many Books one `batch/get` asks for.
    public static let bookDataBatchSize = 50

    /// Fetches full data for every Book that's behind, in batches of ``bookDataBatchSize``, one transaction per
    /// batch, so an interrupted sync resumes from whatever is still behind.
    ///
    /// A batch the Server answers with an error is skipped (its Books stay behind for the next sync); the Server
    /// being unreachable stops the stage. Returns `nil` to keep stage 1's outcome, or `.needsSignIn`.
    func fetchFullData(of identity: ServerIdentity) async -> SyncOutcome? {
        let behind: [String]
        do {
            behind = try database.booksBehindOnFullData()
        } catch {
            log.error("Couldn't read which Books are behind: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard !behind.isEmpty else { return nil }
        log.info("Fetching full data for \(behind.count) Books")
        let api = api
        for start in stride(from: 0, to: behind.count, by: Self.bookDataBatchSize) {
            let ids = Array(behind[start..<min(start + Self.bookDataBatchSize, behind.count)])
            do {
                let books = try await auth.authorized { token throws(ServerAPIError) in
                    try await api.bookData(for: ids, on: identity.serverURL, accessToken: token)
                }
                try database.applyBookData(books)
            } catch AuthError.needsSignIn {
                return .needsSignIn
            } catch AuthError.server(.unreachable) {
                log.info("Stage 2 stopped: the Server can't be reached")
                return nil
            } catch {
                log.info("A batch of full Book data failed: \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    /// Fetches one Book's full data straight away (`GET /api/items/:id?expanded=1`) if it's behind, without waiting
    /// for a running sync: for a Book detail opened before stage 2 reached it. Fails quietly.
    public func fetchFullDataNow(ofBook id: String) async {
        let identity: ServerIdentity
        do {
            guard
                let signedIn = try database.serverIdentity(),
                let detail = try database.bookDetail(id: id), !detail.hasCurrentFullData
            else { return }
            identity = signedIn
        } catch {
            log.error("Couldn't read the Book: \(String(describing: error), privacy: .public)")
            return
        }
        do {
            let api = api
            let book = try await auth.authorized { token throws(ServerAPIError) in
                try await api.bookData(for: id, on: identity.serverURL, accessToken: token)
            }
            try database.applyBookData([book])
        } catch {
            log.info("Fetching one Book failed: \(String(describing: error), privacy: .public)")
        }
    }
}
