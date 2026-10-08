import Domain
import Downloads
import Foundation
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
                    makeDownloader: services.downloader
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
    let api: any ServerAPI = AudiobookshelfClient()
    let tokenStore: any TokenStore = KeychainTokenStore()
    let clock: any Clock = SystemClock()
    /// One `Auth` and one Downloads per signed-in identity, shared by everything that needs them (one refresh).
    private var shared: Shared?

    init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Application Support is backed up; the database must stay that way (never excluded).
        database = try AppDatabase.open(at: directory.appending(path: "Logos.sqlite"))
        signIn = SignIn(api: api, tokenStore: tokenStore, database: database)
        // Covers are excluded from backups. Without the directory, the app still works, with placeholders.
        covers = try? CoverFiles(directory: directory.appending(path: "Covers"))
        // Downloads are excluded from backups, and in Application Support so iOS never evicts them.
        downloadFiles = try? DownloadFiles(directory: directory.appending(path: "Downloads"))
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
