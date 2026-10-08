import Domain
import Foundation
import ServerAPI
import Store

/// How a progress fetch ended. Only ``fetched(changedBookIDs:)`` may have changed anything.
public enum ProgressFetchOutcome: Sendable, Hashable {
    /// The Server's progress was fetched and applied; these Books' progress changed.
    case fetched(changedBookIDs: Set<String>)
    /// Signed out: nothing to fetch.
    case notNeeded
    case unreachable
    case needsSignIn
    /// The last sync found the Server too old: nothing was fetched.
    case serverTooOld(found: String)
    /// The Server answered with an error or something unreadable. Nothing was applied.
    case failed
}

/// Picks up progress from the listener's other devices: `GET /api/me/progress`, applied to the Store by
/// last-writer-wins on when the user acted (``ProgressMerge``, ``AppDatabase/applyFetchedProgress(_:)``).
///
/// Runs on launch, on every return to the foreground and on Refresh (``LibrarySync`` calls it), and should run after
/// each successful send of the outbox. One actor, so the work (the Store write included) stays off the main thread;
/// fetches that arrive while one runs share it. Failures are quiet: they're logged and reported as an outcome, and
/// the next trigger tries again.
public actor ProgressSync {
    private let database: AppDatabase
    private let api: any ServerAPI
    private let auth: Auth
    private let connection: Connection?
    private var running: Task<ProgressFetchOutcome, Never>?

    /// - Parameter connection: when it says the Server is too old, nothing is fetched.
    public init(database: AppDatabase, api: any ServerAPI, auth: Auth, connection: Connection? = nil) {
        self.database = database
        self.api = api
        self.auth = auth
        self.connection = connection
    }

    /// Fetches and applies the Server's progress, or joins the fetch already running.
    public func fetch() async -> ProgressFetchOutcome {
        if let running { return await running.value }
        let task = Task { await run() }
        running = task
        let outcome = await task.value
        running = nil
        log.info("Progress fetch: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func run() async -> ProgressFetchOutcome {
        if let found = await connection?.tooOldVersion { return .serverTooOld(found: found) }
        let identity: ServerIdentity
        do {
            guard let signedIn = try database.serverIdentity() else { return .notNeeded }
            identity = signedIn
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
            return .failed
        }
        let records: [FetchedProgress]
        do {
            let api = api
            records = try await auth.authorized { token throws(ServerAPIError) in
                try await api.progress(on: identity.serverURL, accessToken: token)
            }
        } catch .needsSignIn {
            return .needsSignIn
        } catch .server(.unreachable) {
            return .unreachable
        } catch {
            log.info("The progress fetch failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
        do {
            let applied = try Signposts.measureSync(.applyFetchedProgress) {
                try database.applyFetchedProgress(records)
            }
            return .fetched(changedBookIDs: applied.changedBookIDs)
        } catch {
            log.error("Couldn't apply fetched progress: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }
}
