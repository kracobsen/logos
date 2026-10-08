// swift-tools-version: 6.4
// LogosKit: every module of Logos except the thin app target.
//
// The module graph is enforced here. Allowed edges (Domain is the base every module may use):
//
//   Domain     -> (nothing)
//   ServerAPI  -> Domain
//   Store      -> Domain, GRDB
//   Sync       -> Domain, ServerAPI, Store
//   Downloads  -> Domain, ServerAPI, Store
//   Playback   -> Domain, Store            (never ServerAPI: Playback can't reach the network)
//   UI         -> Domain, Store, Sync, Downloads, Playback
//
// `scripts/check-module-graph.sh` fails CI if this manifest or any `import` drifts from that list.
// A new third-party dependency needs an ADR in docs/adr/.

import PackageDescription

/// Swift 6 language mode (from the tools version) already means complete strict concurrency.
let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

/// UI and Playback default to the main actor, as the spec requires.
let mainActorByDefault: [SwiftSetting] =
    strict + [
        .defaultIsolation(MainActor.self)
    ]

let package = Package(
    name: "LogosKit",
    platforms: [.iOS(.v27)],
    products: [
        .library(
            name: "LogosKit",
            targets: ["Domain", "ServerAPI", "Store", "Sync", "Downloads", "Playback", "UI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .target(name: "Domain", swiftSettings: strict),
        .target(name: "ServerAPI", dependencies: ["Domain"], swiftSettings: strict),
        .target(
            name: "Store",
            dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .target(name: "Sync", dependencies: ["Domain", "ServerAPI", "Store"], swiftSettings: strict),
        .target(name: "Downloads", dependencies: ["Domain", "ServerAPI", "Store"], swiftSettings: strict),
        .target(name: "Playback", dependencies: ["Domain", "Store"], swiftSettings: mainActorByDefault),
        .target(
            name: "UI",
            dependencies: ["Domain", "Store", "Sync", "Downloads", "Playback"],
            swiftSettings: mainActorByDefault
        ),

        .testTarget(name: "DomainTests", dependencies: ["Domain"], swiftSettings: strict),
        .testTarget(
            name: "ServerAPITests",
            dependencies: ["ServerAPI", "Domain"],
            resources: [.copy("Payloads")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "StoreTests",
            dependencies: ["Store", "Domain", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "ServerAPI", "Store", "Domain"], swiftSettings: strict),
        .testTarget(
            name: "DownloadsTests",
            dependencies: ["Downloads", "ServerAPI", "Store", "Domain"],
            swiftSettings: strict
        ),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback"], swiftSettings: strict),
        .testTarget(
            name: "UITests",
            dependencies: ["UI", "Sync", "Downloads", "ServerAPI", "Store", "Domain"],
            swiftSettings: strict
        ),

        // Runs against a pinned audiobookshelf in Docker through scripts/integration-test.sh, never against a
        // real Server. Not in the Logos scheme, so scripts/test.sh doesn't run it.
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["ServerAPI", "Sync", "Store", "Domain"],
            swiftSettings: strict
        ),
    ]
)
