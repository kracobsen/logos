import Domain
import Foundation
import Observation
import Store
import Sync

/// The Library tab: every Book as a row, A–Z ignoring a leading The/A/An, with a letter index, plus the sync
/// triggers and their status ("Syncing Library…", "Last updated …", the brief Refresh message).
///
/// Rows come from one lightweight Store query and are all held in memory. They're read straight away in `init`, so a
/// signed-in launch shows real rows in its first frame, then follow the database (ADR 0001).
@Observable
public final class LibraryModel {
    public private(set) var sections: [TitleSection]
    public private(set) var rowCount: Int
    /// When the Library list was last applied, or `nil` before the first successful sync.
    public private(set) var lastUpdated: Date?
    /// A sync this model started is running.
    public private(set) var isSyncing = false
    /// A short message after a manual Refresh that didn't work. The view clears it after a few seconds.
    public private(set) var refreshMessage: String?

    private let database: AppDatabase
    private let sync: LibrarySync

    public init(database: AppDatabase, sync: LibrarySync) {
        self.database = database
        self.sync = sync
        var rows: [LibraryRow] = []
        do {
            rows = try database.libraryRows()
            lastUpdated = try database.lastLibrarySync()
        } catch {
            log.error("Couldn't read the Library: \(String(describing: error), privacy: .public)")
        }
        sections = rows.sectionedByTitle()
        rowCount = rows.count
    }

    /// "Syncing Library…": the first sync is running, so the Library may still be filling in.
    public var showsFirstSync: Bool { isSyncing && lastUpdated == nil }

    /// Follows the rows and the last sync time in the database until cancelled.
    public func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeRows() }
            group.addTask { await self.observeLastUpdated() }
        }
    }

    private func observeRows() async {
        do {
            for try await rows in database.libraryRowUpdates() {
                // Sorting thousands of titles stays off the main thread.
                let sections = await Task.detached(priority: .userInitiated) { rows.sectionedByTitle() }.value
                self.sections = sections
                rowCount = rows.count
            }
        } catch {
            log.error("Stopped observing the Library: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeLastUpdated() async {
        do {
            for try await date in database.lastLibrarySyncUpdates() {
                lastUpdated = date
            }
        } catch {
            log.error("Stopped observing the last sync: \(String(describing: error), privacy: .public)")
        }
    }

    /// The launch trigger. Call after the first frame.
    public func syncOnLaunch() async {
        _ = await run(.launch)
    }

    /// The return-to-foreground trigger. Syncs only if the last success is more than ~15 minutes old.
    public func syncOnForeground() async {
        _ = await run(.foreground)
    }

    /// The manual Refresh in the toolbar menu. Unlike the automatic triggers, it says briefly when it didn't work.
    public func refresh() async {
        refreshMessage = nil
        refreshMessage = Self.message(for: await run(.manual))
    }

    public func dismissRefreshMessage() {
        refreshMessage = nil
    }

    private func run(_ trigger: SyncTrigger) async -> SyncOutcome {
        isSyncing = true
        defer { isSyncing = false }
        return await sync.sync(trigger)
    }

    static func message(for outcome: SyncOutcome) -> String? {
        switch outcome {
        case .synced, .notNeeded: nil
        case .unreachable: "Couldn't reach the Server."
        case .serverTooOld(let found): "Server too old: it runs audiobookshelf \(found), and Logos needs 2.36 or later."
        case .needsSignIn: "Sign in again to sync."
        case .failed: "Couldn't update the Library. Try again later."
        }
    }
}
