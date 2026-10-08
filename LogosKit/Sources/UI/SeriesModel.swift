import Domain
import Foundation
import Observation
import Store
import Sync

/// The Series tab: every Series A–Z, derived from the Books' Series membership.
///
/// Read in `init`, so the tab has real rows in its first frame, then follows the database (ADR 0001).
@Observable
public final class SeriesListModel {
    public private(set) var series: [SeriesSummary]

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
        do {
            series = try database.seriesList()
        } catch {
            log.error("Couldn't read the Series: \(String(describing: error), privacy: .public)")
            series = []
        }
    }

    /// Follows the Series in the database until cancelled.
    public func observe() async {
        do {
            for try await series in database.seriesListUpdates() {
                self.series = series
            }
        } catch {
            log.error("Stopped observing the Series: \(String(describing: error), privacy: .public)")
        }
    }
}

/// One Series page: its Books in reading order (a strip of covers and big sequence numbers) and the one Continue
/// button.
///
/// Read in `init`, then follows the database, so progress or a Download moves the button on by itself.
@Observable
public final class SeriesPageModel {
    public let seriesID: String
    public private(set) var page: SeriesPage?

    private let fallbackName: String
    private let database: AppDatabase
    private let sync: LibrarySync

    /// - Parameter name: shown until (and unless) the Store has the Series, e.g. after its last Book left.
    public init(seriesID: String, name: String, database: AppDatabase, sync: LibrarySync) {
        self.seriesID = seriesID
        self.fallbackName = name
        self.database = database
        self.sync = sync
        do {
            page = try database.seriesPage(id: seriesID)
        } catch {
            log.error("Couldn't read a Series: \(String(describing: error), privacy: .public)")
        }
    }

    public var name: String { page?.name ?? fallbackName }

    /// In reading order.
    public var books: [SeriesBook] { page?.books ?? [] }

    /// "Continue with Book N" / "Download Book N to continue", or `nil` for no button.
    public var continueTarget: SeriesContinue? { page?.continueTarget }

    /// The Continue button was tapped. Returns the Book to open, or `nil` to stay on the page.
    ///
    /// For now it only opens the target Book. Downloads hooks in here for `.download` (start the Download) and
    /// Playback for `.play` (play it); return `nil` once the action no longer needs the Book's detail.
    public func continueTapped() -> String? {
        guard let target = continueTarget else { return nil }
        switch target.action {
        case .play, .download:
            return target.book.id
        }
    }

    /// Follows the Series in the database until cancelled.
    public func observe() async {
        do {
            for try await page in database.seriesPageUpdates(id: seriesID) {
                self.page = page
            }
        } catch {
            log.error("Stopped observing a Series: \(String(describing: error), privacy: .public)")
        }
    }

    /// A Book's detail, opened from this page.
    public func detail(for bookID: String) -> BookDetailModel {
        BookDetailModel(bookID: bookID, database: database, sync: sync)
    }
}

extension BookDetailModel {
    /// The page of a Series this Book belongs to, for its Series link.
    public func seriesPage(for link: SeriesLink) -> SeriesPageModel {
        SeriesPageModel(seriesID: link.seriesID, name: link.name, database: database, sync: sync)
    }
}

extension LibraryModel {
    /// A Series page, opened from the Series tab (or Library search).
    public func seriesPage(id: String, name: String) -> SeriesPageModel {
        SeriesPageModel(seriesID: id, name: name, database: database, sync: sync)
    }
}
