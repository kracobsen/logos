import Foundation
import ServerAPI
import Store
import SwiftUI
import Sync
import UI

/// The composition root. Modules are wired here with plain initializer injection.
@main
struct LogosApp: App {
    private let services: Result<Services, any Error>

    init() {
        services = Result { try Services() }
    }

    var body: some Scene {
        WindowGroup {
            switch services {
            case .success(let services):
                AppRootView(database: services.database, signIn: services.signIn)
            case .failure(let error):
                // The database is never deleted automatically; the full error screen comes with the Store work.
                ContentUnavailableView(
                    "Logos can't open its data",
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: error))
                )
            }
        }
    }
}

/// The long-lived objects the app wires together.
private struct Services {
    let database: AppDatabase
    let signIn: SignIn

    init() throws {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        database = try AppDatabase.open(at: directory.appending(path: "Logos.sqlite"))
        signIn = SignIn(api: AudiobookshelfClient(), tokenStore: KeychainTokenStore(), database: database)
    }
}
