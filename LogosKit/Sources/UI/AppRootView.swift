import Domain
import Downloads
import Playback
import Store
import SwiftUI
import Sync

/// What the app shows: sign-in until a Server identity is saved, then the tab shell.
public struct AppRootView: View {
    @State private var launch: LaunchModel
    @State private var signIn: SignInModel
    private let launchSignpost: LaunchSignpost?
    @State private var covers: CoverImages?
    private let player: Player?
    private let signInService: SignIn
    private let database: AppDatabase
    private let coverFiles: CoverFiles?

    /// - Parameters:
    ///   - makeLibrarySync: builds the sync for a signed-in identity.
    ///   - covers: where the cover files are. Without it, covers show as placeholders.
    ///   - makeDownloader: gives the Downloads for a signed-in identity.
    ///   - player: plays downloaded Books (one for the whole app).
    ///   - onSignedOut: after the sign-out wipe: drop the identity's `Auth` and Downloads.
    public init(
        database: AppDatabase,
        signIn: SignIn,
        makeLibrarySync: @escaping (ServerIdentity) -> LibrarySync,
        launchSignpost: LaunchSignpost? = nil,
        covers: CoverFiles? = nil,
        makeDownloader: ((ServerIdentity) -> Downloader?)? = nil,
        player: Player? = nil,
        onSignedOut: (() -> Void)? = nil
    ) {
        _covers = State(initialValue: covers.map { CoverImages(database: database, files: $0) })
        _launch = State(
            initialValue: LaunchModel(
                database: database, makeLibrarySync: makeLibrarySync, makeDownloader: makeDownloader,
                player: player, signIn: signIn, covers: covers, onSignedOut: onSignedOut))
        _signIn = State(initialValue: SignInModel(signIn: signIn))
        self.launchSignpost = launchSignpost
        self.player = player
        signInService = signIn
        self.database = database
        coverFiles = covers
    }

    public var body: some View {
        Group {
            if let library = launch.library, let inProgress = launch.inProgress, let series = launch.series {
                RootView(
                    library: library, inProgress: inProgress, series: series, launch: launchSignpost, covers: covers,
                    downloads: launch.downloads, player: player, settings: launch.settings,
                    listening: launch.listening, signInAgain: launch.signInAgain)
            } else {
                SignInView(model: signIn)
                    .onAppear { launchSignpost?.end() }
            }
        }
        .task { await launch.observe() }
        .onChange(of: launch.identity == nil) { _, signedOut in
            guard signedOut else { return }
            // Like a fresh install: an empty sign-in form, and no covers cached from the old Library.
            signIn = SignInModel(signIn: signInService)
            covers = coverFiles.map { CoverImages(database: database, files: $0) }
        }
    }
}

/// Shown instead of everything else when the database can't be opened or migrated. The file is kept as it is.
public struct DatabaseErrorView: View {
    let error: any Error

    public init(error: any Error) {
        self.error = error
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Logos can't open its data", systemImage: "exclamationmark.triangle")
        } description: {
            Text(
                """
                Your Library and listening data are still on this iPhone; nothing has been deleted. \
                Try updating Logos, or restarting your iPhone.
                """
            )
            Text(String(describing: error))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
