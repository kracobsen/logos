import Domain
import Foundation
import ServerAPI
import Store
import SwiftUI
import Sync
import UI

/// The composition root. Modules are wired here with plain initializer injection.
@main
struct LogosApp: App {
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
                    launchSignpost: launchSignpost
                )
            case .failure(let error):
                // The database is never deleted automatically: say so, and keep the file.
                DatabaseErrorView(error: error)
            }
        }
    }
}

/// The long-lived objects the app wires together.
private struct Services {
    let database: AppDatabase
    let signIn: SignIn
    let api: any ServerAPI = AudiobookshelfClient()
    let tokenStore: any TokenStore = KeychainTokenStore()
    let clock: any Clock = SystemClock()

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
    }

    /// The sync for a signed-in identity, with the `Auth` for its Server.
    func makeLibrarySync(for identity: ServerIdentity) -> LibrarySync {
        let auth = Auth(server: identity.serverURL, api: api, tokenStore: tokenStore, clock: clock)
        return LibrarySync(database: database, api: api, auth: auth, clock: clock)
    }
}
