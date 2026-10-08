import Domain
import Foundation
import ServerAPI
import Store

/// Finished changes, sent with the outbox (`PATCH /api/me/progress/:libraryItemId`, one per Book).
///
/// The order within one send:
/// 1. **Guard fetch**, before any session goes: if the Server's progress was changed after the listener acted, the
///    change is dropped and the Server's state applied. It comes before the sessions because the Server stamps
///    progress that a session *creates* with its own time, which would otherwise look newer than the change.
/// 2. The sessions (``SessionOutbox``).
/// 3. Each change whose Book has no unsent sessions left is sent. If this send delivered that Book's sessions, the
///    Server's progress is fetched again first: a session that reached the end has finished the Book there already,
///    and one played from a Finished Book has cleared it, and then nothing is sent (a PATCH would only move the
///    Server's time back).
extension SessionOutbox {
    /// Sends whenever a new Finished change is queued, until cancelled. Finished set or cleared by hand on a Book
    /// that isn't playing stops nothing, so the other triggers wouldn't send it until the next foreground.
    public func sendOnFinishedChanges() async {
        var known: Set<FinishedChange>?
        do {
            for try await changes in database.pendingFinishedChangeUpdates() {
                let current = Set(changes)
                defer { known = current }
                guard let known, !current.isSubset(of: known) else { continue }
                await send()
            }
        } catch {
            log.error("Couldn't observe Finished changes: \(String(describing: error), privacy: .public)")
        }
    }

    /// How the guard fetch went: the changes still to send and the Server's progress, or an outcome to stop with.
    enum FinishedGuard {
        case checked([PendingFinishedChange], server: [FetchedProgress])
        case stop(OutboxSendOutcome)
    }

    /// Step 1. A fetch the Server answered with an error skips the changes this time and lets the sessions go.
    func guardFinishedChanges(_ changes: [PendingFinishedChange], on identity: ServerIdentity) async -> FinishedGuard {
        let records: [FetchedProgress]
        switch await fetchServerProgress(on: identity) {
        case .success(let fetched): records = fetched
        case .failure(let stop) where stop.outcome == .failed: return .checked([], server: [])
        case .failure(let stop): return .stop(stop.outcome)
        }
        do {
            let dropped = try database.dropFinishedChanges(overruledBy: records)
            try database.applyFetchedProgress(records)
            if !dropped.isEmpty {
                log.info("Dropped \(dropped.count) Finished changes made before a newer one elsewhere")
            }
            return .checked(changes.filter { !dropped.contains($0.change.bookID) }, server: records)
        } catch {
            log.error("Couldn't apply the guard fetch: \(String(describing: error), privacy: .public)")
            return .checked([], server: [])
        }
    }

    /// Step 3. Returns the delivered and rejected counts, or an outcome to stop with.
    func sendFinishedChanges(
        _ changes: [PendingFinishedChange], server guarded: [FetchedProgress],
        sessionsSentFor sessionBooks: Set<String>,
        on identity: ServerIdentity
    ) async -> Result<(delivered: Int, rejected: Int), FinishedStop> {
        let waiting: Set<String>
        do {
            waiting = try database.bookIDsWithUnsentSessions()
        } catch {
            log.error("Couldn't read the outbox: \(String(describing: error), privacy: .public)")
            return .success((0, 0))
        }
        let ready = changes.filter { !waiting.contains($0.change.bookID) }
        guard !ready.isEmpty else { return .success((0, 0)) }
        var records = guarded
        if ready.contains(where: { sessionBooks.contains($0.change.bookID) }) {
            switch await fetchServerProgress(on: identity) {
            case .success(let fetched): records = fetched
            case .failure(let stop) where stop.outcome == .failed: return .success((0, 0))
            case .failure(let stop): return .failure(stop)
            }
        }
        let server = Dictionary(records.map { ($0.bookID, $0) }, uniquingKeysWith: { first, _ in first })
        var delivered = 0
        var rejected = 0
        for pending in ready {
            let change = pending.change
            if !FinishedChanges.isOnServer(change, server: server[change.bookID]) {
                do {
                    let api = api
                    try await auth.authorized { token throws(ServerAPIError) in
                        try await api.updateFinished(
                            change, duration: pending.duration, on: identity.serverURL, accessToken: token)
                    }
                } catch .needsSignIn {
                    return .failure(FinishedStop(outcome: .needsSignIn))
                } catch .server(.unreachable) {
                    return .failure(FinishedStop(outcome: .unreachable))
                } catch .server(.unexpectedStatus(let status)) where status == 404 || status == 400 {
                    rejected += 1
                    rejectBook(change.bookID)
                    log.notice("The Server rejected a Finished change: \(status)")
                    continue
                } catch {
                    log.info("Sending a Finished change failed: \(String(describing: error), privacy: .public)")
                    continue
                }
            }
            do {
                try database.confirmFinishedChange(change)
                delivered += 1
            } catch {
                log.error("Couldn't confirm a Finished change: \(String(describing: error), privacy: .public)")
            }
        }
        return .success((delivered, rejected))
    }

    struct FinishedStop: Error {
        let outcome: OutboxSendOutcome
    }

    private func fetchServerProgress(on identity: ServerIdentity) async -> Result<[FetchedProgress], FinishedStop> {
        do {
            let api = api
            return .success(
                try await auth.authorized { token throws(ServerAPIError) in
                    try await api.progress(on: identity.serverURL, accessToken: token)
                })
        } catch .needsSignIn {
            return .failure(FinishedStop(outcome: .needsSignIn))
        } catch .server(.unreachable) {
            return .failure(FinishedStop(outcome: .unreachable))
        } catch {
            log.info("The guard fetch failed: \(String(describing: error), privacy: .public)")
            return .failure(FinishedStop(outcome: .failed))
        }
    }
}
