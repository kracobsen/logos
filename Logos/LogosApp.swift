import Domain
import Downloads
import Foundation
import Playback
import ServerAPI
import Store
import SwiftUI
import Sync
import UI

/// The composition root. Modules are wired here with plain initializer injection.
@main
struct LogosApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let launchSignpost = LaunchSignpost()
    private let services: Result<Services, any Error>

    init() {
        services = Result { try Services() }
    }

    var body: some Scene {
        WindowGroup {
            switch services {
            case .success(let services):
                AppRootView(
                    database: services.database,
                    signIn: services.signIn,
                    makeLibrarySync: services.makeLibrarySync,
                    launchSignpost: launchSignpost,
                    covers: services.covers,
                    makeDownloader: services.downloader,
                    player: services.player
                )
            case .failure(let error):
                // The database is never deleted automatically: say so, and keep the file.
                DatabaseErrorView(error: error)
            }
        }
    }
}

/// Hands the background session's events to Downloads when the system launches or wakes Logos for them.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == Services.transfersIdentifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        Services.transfers.handleEventsForBackgroundSession { completion() }
    }
}

/// The long-lived objects the app wires together.
private final class Services {
    /// The fixed identifier of the one background session for Downloads.
    static let transfersIdentifier = "\(Bundle.main.bundleIdentifier ?? "logos").downloads"
    /// Built once per process, as early as possible, so the background session reconnects and hears its events.
    static let transfers = BackgroundFileTransfers(
        configuration: BackgroundFileTransfers.backgroundConfiguration(identifier: transfersIdentifier))

    private struct Shared {
        let identity: ServerIdentity
        let auth: Auth
        let downloader: Downloader?
    }

    let database: AppDatabase
    let signIn: SignIn
    let covers: CoverFiles?
    let downloadFiles: DownloadFiles?
    /// One player for the whole app: it plays from Downloads only (never the network).
    let player: Player?
    /// The lock screen and Control Center for the player.
    let nowPlaying: NowPlaying?
    let api: any ServerAPI
    let tokenStore: any TokenStore
    let clock: any Clock = SystemClock()
    /// One `Auth` and one Downloads per signed-in identity, shared by everything that needs them (one refresh).
    private var shared: Shared?

    init() throws {
        let backend = try Backend.forThisLaunch()
        let directory = backend.directory
        api = backend.api
        tokenStore = backend.tokenStore
        database = try AppDatabase.open(at: directory.appending(path: "Logos.sqlite"))
        // Before anything can play: a listening session still open now was left open by a kill.
        try? database.closeListeningSessionsLeftOpen()
        signIn = SignIn(
            api: api, tokenStore: tokenStore, database: database,
            allowsPlainHTTPOnLoopback: backend.allowsPlainHTTPOnLoopback)
        // Covers are excluded from backups. Without the directory, the app still works, with placeholders.
        covers = try? CoverFiles(directory: directory.appending(path: "Covers"))
        // Downloads are excluded from backups, and in Application Support so iOS never evicts them.
        downloadFiles = try? DownloadFiles(directory: directory.appending(path: "Downloads"))
        player = downloadFiles.map { [database, clock] in
            Player(
                database: database, files: $0, audio: SystemAudioPlayer(), clock: clock,
                session: SystemAudioSession())
        }
        nowPlaying = player.map { [covers, clock] in
            NowPlaying(player: $0, center: SystemNowPlayingCenter(), covers: covers, clock: clock)
        }
        if let nowPlaying { Task { await nowPlaying.follow() } }
        // A background launch for finished transfers has no UI: start Downloads now so it handles them.
        if let identity = try? database.serverIdentity(), let downloader = downloader(for: identity) {
            Task { await downloader.start() }
        }
    }

    /// The sync for a signed-in identity, with the identity's shared `Auth`.
    func makeLibrarySync(for identity: ServerIdentity) -> LibrarySync {
        LibrarySync(database: database, api: api, auth: shared(for: identity).auth, clock: clock, covers: covers)
    }

    /// The Downloads for a signed-in identity, or `nil` if the Downloads directory couldn't be made.
    func downloader(for identity: ServerIdentity) -> Downloader? {
        shared(for: identity).downloader
    }

    private func shared(for identity: ServerIdentity) -> Shared {
        if let shared, shared.identity == identity { return shared }
        let auth = Auth(server: identity.serverURL, api: api, tokenStore: tokenStore, clock: clock)
        let downloader = downloadFiles.map {
            Downloader(
                database: database, api: api, auth: auth, transfers: Self.transfers, files: $0, covers: covers,
                clock: clock, inForeground: false)  // the UI's launch task calls resume()
        }
        let made = Shared(identity: identity, auth: auth, downloader: downloader)
        shared = made
        return made
    }
}
