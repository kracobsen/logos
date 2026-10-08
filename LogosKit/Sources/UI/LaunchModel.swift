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
            listening = library.map(makeListening)
            makeConnectionModels()
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
    /// The listening-sessions outbox's send triggers, while signed in.
    public private(set) var listening: ListeningReporter?
    /// The Settings screen's model, while signed in.
    public private(set) var settings: SettingsModel?
    /// The needs-sign-in (and Server too old) banner and the sign-in sheet, while signed in.
    public private(set) var signInAgain: SignInAgainModel?
    /// Sign out (in Settings), while signed in.
    public private(set) var signOut: SignOutModel?

    private let database: AppDatabase
    private let makeLibrarySync: (ServerIdentity) -> LibrarySync
    private let makeDownloader: ((ServerIdentity) -> Downloader?)?
    private let player: Player?
    private let signIn: SignIn?
    private let covers: CoverFiles?
    private let onSignedOut: (() -> Void)?

    /// - Parameters:
    ///   - makeLibrarySync: builds the sync for a signed-in identity (its Server and Library).
    ///   - makeDownloader: gives the Downloads for a signed-in identity. Without it, Download buttons do nothing.
    ///   - player: stopped before the Download of the Book it plays is removed.
    ///   - signIn: for signing in again from needs sign-in. Without it, there's no sign-in sheet.
    ///   - covers: deleted when signing out.
    ///   - onSignedOut: after the sign-out wipe; the app drops the identity's `Auth` and Downloads there.
    public init(
        database: AppDatabase,
        makeLibrarySync: @escaping (ServerIdentity) -> LibrarySync,
        makeDownloader: ((ServerIdentity) -> Downloader?)? = nil,
        player: Player? = nil,
        signIn: SignIn? = nil,
        covers: CoverFiles? = nil,
        onSignedOut: (() -> Void)? = nil
    ) {
        self.database = database
        self.makeLibrarySync = makeLibrarySync
        self.makeDownloader = makeDownloader
        self.player = player
        self.signIn = signIn
        self.covers = covers
        self.onSignedOut = onSignedOut
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
        listening = library.map(makeListening)
        makeConnectionModels()
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

    /// Builds (or drops) the banner, sign-in sheet and sign-out models for the current identity.
    private func makeConnectionModels() {
        guard let identity, let library else {
            signInAgain = nil
            signOut = nil
            return
        }
        let sync = library.sync
        let downloads = downloads
        signInAgain = signIn.map { signIn in
            SignInAgainModel(identity: identity, connection: sync.connection, signIn: signIn) {
                // Sending first: the sync's progress fetch then never meets this device's unsent listening.
                await sync.outbox.send()
                async let synced = sync.sync(.manual)
                await downloads?.resume()
                _ = await synced
            }
        }
        let signOut = SignOutModel(
            database: database, sync: sync, downloader: makeDownloader?(identity) ?? nil, player: player,
            covers: covers, onSignedOut: onSignedOut)
        self.signOut = signOut
        settings?.signOut = signOut
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

    private func makeListening(for library: LibraryModel) -> ListeningReporter {
        ListeningReporter(outbox: library.sync.outbox, player: player)
    }

    private func makeLibrary(for identity: ServerIdentity) -> LibraryModel {
        LibraryModel(database: database, sync: makeLibrarySync(identity))
    }
}
