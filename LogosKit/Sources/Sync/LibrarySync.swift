import Domain
import Foundation
import ServerAPI
import Store

/// What started a sync.
public enum SyncTrigger: Sendable, Hashable {
    /// The app launched (sync after the first frame).
    case launch
    /// The app came back to the foreground. Syncs only if the last successful sync is older than
    /// ``LibrarySync/foregroundInterval``.
    case foreground
    /// The user chose Refresh.
    case manual
}

/// How a sync ended. Only ``synced`` changed anything; every other outcome leaves the Store as it was.
public enum SyncOutcome: Sendable, Hashable {
    /// The Library list was applied.
    case synced
    /// Nothing to do: signed out, or a foreground return soon after the last successful sync.
    case notNeeded
    /// The Server couldn't be reached (offline, DNS, timeout...).
    case unreachable
    /// The Server runs a version below 2.36 (or one that can't be read). Syncing stops until it's upgraded.
    case serverTooOld(found: String)
    /// The Server rejected the sign-in. Sync pauses until the user signs in again.
    case needsSignIn
    /// The Server answered, but with an error, an empty list or one that can't be read. Nothing was applied.
    case failed
}

/// The catalogue sync: keeps the Store's Library in step with the Server.
///
/// One actor, so the work runs off the main thread, and triggers that arrive while a sync runs share it rather than
/// starting another. Each sync:
/// 1. rechecks the Server version (`/status`) and stops below 2.36;
/// 2. stage 1: fetches the full Library list and applies it to the Store in one transaction, deleting Books the
///    Server no longer lists. An empty, failed or undecodable list is never applied.
/// 3. stage 2: fetches full Book data for every Book that's behind (`LibrarySync+BookData.swift`);
/// 4. stage 3: fetches covers that are behind (`CoverSync`).
///
/// Sync never throws and never blocks the UI:
/// failures are logged and reported as a ``SyncOutcome``.
public actor LibrarySync {
    /// A foreground return syncs only if the last successful sync is older than this.
    public static let foregroundInterval: Duration = .seconds(15 * 60)

    let database: AppDatabase
    let api: any ServerAPI
    let auth: Auth
    let clock: any Clock
    private var running: Task<SyncOutcome, Never>?
    private let coverSync: CoverSync?

    /// - Parameter covers: where stage 3 keeps covers. Without it, covers aren't synced.
    public init(database: AppDatabase, api: any ServerAPI, auth: Auth, clock: any Clock, covers: CoverFiles? = nil) {
        self.database = database
        self.api = api
        self.auth = auth
        self.clock = clock
        coverSync = covers.map { CoverSync(database: database, api: api, auth: auth, covers: $0) }
    }

    /// Syncs, or joins the sync already running.
    public func sync(_ trigger: SyncTrigger) async -> SyncOutcome {
        if let running { return await running.value }
        if trigger == .foreground, !isDueOnForeground() { return .notNeeded }
        let task = Task { await run() }
        running = task
        let outcome = await task.value
        running = nil
        log.info(
            "Sync (\(String(describing: trigger), privacy: .public)): \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func isDueOnForeground() -> Bool {
        do {
            guard let last = try database.lastLibrarySync() else { return true }
            return clock.now.timeIntervalSince(last) > Self.foregroundInterval.seconds
        } catch {
            log.error("Couldn't read the last sync time: \(String(describing: error), privacy: .public)")
            return true
        }
    }

    private func run() async -> SyncOutcome {
        let identity: ServerIdentity
        let isFirstSync: Bool
        do {
            guard let signedIn = try database.serverIdentity() else { return .notNeeded }
            identity = signedIn
            isFirstSync = try database.lastLibrarySync() == nil
        } catch {
            log.error("Couldn't read the sync state: \(String(describing: error), privacy: .public)")
            return .failed
        }
        let interval = Signposts.begin(isFirstSync ? .firstSync : .syncWithNoChanges)
        defer { interval.end() }

        if let stop = await checkVersion(of: identity.serverURL) { return stop }
        let outcome = await applyList(of: identity)
        guard outcome == .synced else { return outcome }
        // Stage 2: full Book data. Only a rejected sign-in changes the outcome.
        if let stop = await fetchFullData(of: identity) { return stop }
        // Stage 3: covers. Failures leave them behind for the next sync; they don't change the outcome.
        await coverSync?.run(on: identity.serverURL)
        return outcome
    }

    /// `nil` if the Server may be synced with, otherwise why not.
    private func checkVersion(of server: URL) async -> SyncOutcome? {
        do {
            let status = try await api.status(of: server)
            guard status.isSupported else {
                log.notice("Server version \(status.reportedVersion, privacy: .public) is below 2.36: not syncing")
                return .serverTooOld(found: status.reportedVersion)
            }
            return nil
        } catch .unreachable {
            return .unreachable
        } catch {
            log.info("Status failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

    /// Stage 1.
    private func applyList(of identity: ServerIdentity) async -> SyncOutcome {
        let books: [ListedBook]
        do {
            let api = api
            books = try await auth.authorized { token throws(ServerAPIError) in
                try await api.books(inLibrary: identity.libraryID, on: identity.serverURL, accessToken: token)
            }
        } catch .needsSignIn {
            return .needsSignIn
        } catch .server(.unreachable) {
            return .unreachable
        } catch {
            log.info("The Library list failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
        guard !books.isEmpty else {
            log.notice("The Server sent an empty Library list: not applied")
            return .failed
        }
        do {
            let applied = try database.applyLibraryList(books, syncedAt: clock.now)
            log.info("Applied \(books.count) Books, removed \(applied.removedBookIDs.count)")
            return .synced
        } catch {
            log.error("Couldn't apply the Library list: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
