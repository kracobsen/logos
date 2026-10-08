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
    /// The rows to show, in the current sort, filter and search. Sectioned by letter when ``showsIndex``.
    public private(set) var sections: [TitleSection]
    /// Every Book in the Library, whatever the filter and search.
    public private(set) var rowCount: Int
    /// While searching: the Series whose name matches, shown above the Books.
    public private(set) var seriesResults: [LibrarySeries] = []
    /// Whether the letter index shows: Title and Author order, not while searching.
    public private(set) var showsIndex = true
    /// When the Library list was last applied, or `nil` before the first successful sync.
    public private(set) var lastUpdated: Date?
    /// A sync this model started is running.
    public private(set) var isSyncing = false
    /// The sync running started before the Library was ever synced: it's the first sync, until all its stages end.
    private var isFirstSync = false
    /// A short message after a manual Refresh that didn't work. The view clears it after a few seconds.
    public private(set) var refreshMessage: String?

    public var sort: LibrarySort = .title {
        didSet {
            guard sort != oldValue else { return }
            Signposts.measureSync(.sortChange) {
                order = catalog.ordered(by: sort, progress: progress)
                showResults()
            }
        }
    }

    public var filter: LibraryFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            showResults()
        }
    }

    /// The search field's text. Blank is no search.
    public var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            Signposts.measureSync(.searchKeystroke) { showResults() }
        }
    }

    public var isSearching: Bool { SearchFolding.needle(searchText) != nil }

    let database: AppDatabase
    let sync: LibrarySync

    @ObservationIgnored private var rows: [LibraryRow]
    @ObservationIgnored private var series: [LibrarySeries]
    @ObservationIgnored private var progress: [String: BookProgress]
    @ObservationIgnored private var catalog: LibraryCatalog
    @ObservationIgnored private var order: LibraryOrder
    /// Counts catalog rebuilds, so a slower older one never replaces a newer one.
    @ObservationIgnored private var catalogGeneration = 0

    public init(database: AppDatabase, sync: LibrarySync) {
        self.database = database
        self.sync = sync
        var rows: [LibraryRow] = []
        var series: [LibrarySeries] = []
        var progress: [String: BookProgress] = [:]
        do {
            rows = try database.libraryRows()
            series = try database.librarySeries()
            progress = try database.progressByBook()
            lastUpdated = try database.lastLibrarySync()
        } catch {
            log.error("Couldn't read the Library: \(String(describing: error), privacy: .public)")
        }
        self.rows = rows
        self.series = series
        self.progress = progress
        catalog = LibraryCatalog(rows: rows, series: series)
        order = catalog.ordered(by: .title, progress: progress)
        let results = order.results(filter: .all, search: "", progress: progress)
        sections = results.sections
        showsIndex = results.showsIndex
        rowCount = rows.count
    }

    /// Shows the current order with the current filter and search.
    private func showResults() {
        let results = order.results(filter: filter, search: searchText, progress: progress)
        sections = results.sections
        seriesResults = results.series
        showsIndex = results.showsIndex
    }

    /// "Syncing Library…": the first sync is running (all its stages, not just the list), so the Library may still be
    /// filling in.
    public var showsFirstSync: Bool { isSyncing && isFirstSync }

    /// Follows the rows, Series, progress and last sync time in the database until cancelled.
    public func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeRows() }
            group.addTask { await self.observeSeries() }
            group.addTask { await self.observeProgress() }
            group.addTask { await self.observeLastUpdated() }
        }
    }

    private func observeRows() async {
        do {
            for try await rows in database.libraryRowUpdates() where rows != self.rows {
                self.rows = rows
                await rebuildCatalog()
            }
        } catch {
            log.error("Stopped observing the Library: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeSeries() async {
        do {
            for try await series in database.librarySeriesUpdates() where Set(series) != Set(self.series) {
                self.series = series
                await rebuildCatalog()
            }
        } catch {
            log.error("Stopped observing Series: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeProgress() async {
        do {
            for try await progress in database.progressByBookUpdates() where progress != self.progress {
                self.progress = progress
                if sort == .recentlyListened {
                    order = catalog.ordered(by: sort, progress: progress)
                }
                showResults()
            }
        } catch {
            log.error("Stopped observing progress: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sorts and folds thousands of rows off the main thread, then shows them in the current sort.
    private func rebuildCatalog() async {
        catalogGeneration += 1
        let generation = catalogGeneration
        let (rows, series, sort, progress) = (rows, series, sort, progress)
        let (catalog, order) = await Task.detached(priority: .userInitiated) {
            let catalog = LibraryCatalog(rows: rows, series: series)
            return (catalog, catalog.ordered(by: sort, progress: progress))
        }.value
        guard generation == catalogGeneration else { return }
        self.catalog = catalog
        self.order = order.sort == self.sort ? order : catalog.ordered(by: self.sort, progress: self.progress)
        rowCount = rows.count
        showResults()
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

    /// How long the Refresh message shows.
    static let refreshMessageDuration = Duration.seconds(4)

    /// Shows the Refresh message for ``refreshMessageDuration``, then clears it (on the sync's Clock).
    func dismissRefreshMessageLater() async {
        do {
            try await sync.clock.sleep(for: Self.refreshMessageDuration)
        } catch {
            return
        }
        dismissRefreshMessage()
    }

    private func run(_ trigger: SyncTrigger) async -> SyncOutcome {
        isSyncing = true
        isFirstSync = lastUpdated == nil
        defer {
            isSyncing = false
            isFirstSync = false
        }
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
