import Foundation
import ServerAPI

/// Where the app keeps its data and how it reaches Servers.
///
/// A normal launch uses Application Support, the real Server API and the Keychain, and signs in over HTTPS only. Builds
/// with the `LOGOS_TEST_LAUNCH` condition (Debug and Performance, never Release) can be launched against test data
/// instead: see `TestLaunch`.
struct Backend {
    /// Holds the database, Covers and Downloads.
    let directory: URL
    let api: any ServerAPI
    let tokenStore: any TokenStore
    /// Lets sign-in use plain HTTP to a loopback Server (the local Docker Server). Only test launches set it.
    var allowsPlainHTTPOnLoopback = false

    static func forThisLaunch() throws -> Backend {
        #if LOGOS_TEST_LAUNCH
            if let backend = try TestLaunch.backend() { return backend }
        #endif
        return try Backend(
            directory: applicationSupport(), api: AudiobookshelfClient(), tokenStore: KeychainTokenStore())
    }

    static func applicationSupport() throws -> URL {
        // Application Support is backed up; the database must stay that way (never excluded).
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
