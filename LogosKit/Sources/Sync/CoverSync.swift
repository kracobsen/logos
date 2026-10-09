import Domain
import Foundation
import ServerAPI
import Store

extension LibrarySync {
    /// How many covers stage 3 fetches at once.
    public static let coverConcurrency = 4
}

/// Stage 3 of the sync: brings every Book's cover file up to its `updatedAt`.
///
/// Covers whose version is behind are fetched ``LibrarySync/coverConcurrency`` at a time, each saved to
/// ``CoverFiles`` and then recorded in the Store, so an interrupted run continues from what's still behind. A cover
/// that fails stays behind for the next sync. A 404, or a Book the Server lists without a cover, means no cover: any
/// old file is deleted and the version is recorded, so it isn't asked for again until the Book changes. Cover files
/// whose Book is gone are deleted first.
struct CoverSync: Sendable {
    let database: AppDatabase
    let api: any ServerAPI
    let auth: Auth
    let covers: CoverFiles

    func run(on server: URL) async {
        let behind: [CoverToFetch]
        do {
            try deleteOrphans()
            behind = try database.coversBehind()
        } catch {
            log.error("Couldn't read the covers behind: \(String(describing: error), privacy: .public)")
            return
        }
        var toFetch: [CoverToFetch] = []
        for cover in behind {
            if cover.hasCover {
                toFetch.append(cover)
            } else {
                record(noCoverFor: cover)
            }
        }
        guard !toFetch.isEmpty else { return }

        var pending = toFetch[...]
        var fetched = 0
        await withTaskGroup(of: Result.self) { group in
            for _ in 0..<min(LibrarySync.coverConcurrency, pending.count) {
                let cover = pending.removeFirst()
                group.addTask { await fetch(cover, from: server) }
            }
            while let result = await group.next() {
                switch result {
                case .fetched:
                    fetched += 1
                case .skipped:
                    break
                case .stop:
                    // Offline, or signed out: the rest would fail the same way.
                    pending.removeAll()
                    group.cancelAll()
                }
                if let cover = pending.popFirst() {
                    group.addTask { await fetch(cover, from: server) }
                }
            }
        }
        log.info("Fetched \(fetched) of \(toFetch.count) covers")
    }

    private enum Result: Sendable {
        case fetched, skipped, stop
    }

    private func fetch(_ cover: CoverToFetch, from server: URL) async -> Result {
        let data: Data
        do {
            let api = api
            data = try await auth.authorized { token throws(ServerAPIError) in
                try await api.cover(ofBook: cover.bookID, on: server, accessToken: token)
            }
        } catch .server(.unexpectedStatus(404)) {
            record(noCoverFor: cover)
            return .skipped
        } catch .needsSignIn, .server(.unreachable) {
            return .stop
        } catch {
            log.info("A cover failed: \(String(describing: error), privacy: .public)")
            return .skipped
        }
        do {
            try covers.save(data, forBook: cover.bookID)
            try database.setCoverVersion(cover.version, forBook: cover.bookID)
            return .fetched
        } catch {
            log.error("Couldn't save a cover: \(String(describing: error), privacy: .public)")
            return .skipped
        }
    }

    private func record(noCoverFor cover: CoverToFetch) {
        covers.delete(forBook: cover.bookID)
        do {
            try database.setCoverVersion(cover.version, forBook: cover.bookID)
        } catch {
            log.error("Couldn't record a missing cover: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes the cover files of Books the Store no longer has (removed from the Server).
    private func deleteOrphans() throws {
        let books = try database.bookIDs()
        for bookID in try covers.bookIDs().subtracting(books) {
            covers.delete(forBook: bookID)
        }
    }
}
