import Domain
import Downloads
import Observation
import Playback
import Store
import Sync

/// Decides what launch shows: sign-in when signed out, the tab shell when a Server identity is saved.
///
/// Reads the identity straight away, so a signed-in launch shows the tab shell (with its Library rows) in its first
/// frame, then follows the database (ADR 0001). While signed in it holds the Library tab's model, built for that
/// identity.
@Observable
public final class LaunchModel {
    public private(set) var identity: ServerIdentity? {
        didSet {
            guard identity != oldValue else { return }
            library = identity.map(makeLibrary)
            inProgress = identity.map { _ in InProgressModel(database: database) }
            series = identity.map { _ in SeriesListModel(database: database) }
            downloads = identity.map(makeDownloads)
            settings = identity.map(makeSettings)
        }
    }
    /// The Library tab's model, while signed in.
    public private(set) var library: LibraryModel?
    /// The In Progress tab's model, while signed in.
    public private(set) var inProgress: InProgressModel?
    /// The Series tab's model, while signed in.
    public private(set) var series: SeriesListModel?
    /// Downloads (the Downloaded tab, Download buttons), while signed in.
    public private(set) var downloads: DownloadsModel?
    /// The Settings screen's model, while signed in.
    public private(set) var settings: SettingsModel?

    private let database: AppDatabase
    private let makeLibrarySync: (ServerIdentity) -> LibrarySync
    private let makeDownloader: ((ServerIdentity) -> Downloader?)?
    private let player: Player?

    /// - Parameters:
    ///   - makeLibrarySync: builds the sync for a signed-in identity (its Server and Library).
    ///   - makeDownloader: gives the Downloads for a signed-in identity. Without it, Download buttons do nothing.
    ///   - player: stopped before the Download of the Book it plays is removed.
    public init(
        database: AppDatabase,
        makeLibrarySync: @escaping (ServerIdentity) -> LibrarySync,
        makeDownloader: ((ServerIdentity) -> Downloader?)? = nil,
        player: Player? = nil
    ) {
        self.database = database
        self.makeLibrarySync = makeLibrarySync
        self.makeDownloader = makeDownloader
        self.player = player
        do {
            identity = try database.serverIdentity()
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
        }
        library = identity.map(makeLibrary)
        inProgress = identity.map { _ in InProgressModel(database: database) }
        series = identity.map { _ in SeriesListModel(database: database) }
        downloads = identity.map(makeDownloads)
        settings = identity.map(makeSettings)
    }

    /// Follows the identity in the database until cancelled.
    public func observe() async {
        do {
            for try await identity in database.serverIdentityUpdates() {
                self.identity = identity
            }
        } catch {
            log.error("Stopped observing the Server identity: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeSettings(for identity: ServerIdentity) -> SettingsModel {
        let settings = SettingsModel(database: database, downloader: makeDownloader?(identity) ?? nil)
        settings.player = player
        return settings
    }

    private func makeDownloads(for identity: ServerIdentity) -> DownloadsModel {
        let downloads = DownloadsModel(
            database: database, downloader: makeDownloader?(identity) ?? nil, network: SystemNetworkMonitor())
        downloads.player = player
        return downloads
    }

    private func makeLibrary(for identity: ServerIdentity) -> LibraryModel {
        LibraryModel(database: database, sync: makeLibrarySync(identity))
    }
}
