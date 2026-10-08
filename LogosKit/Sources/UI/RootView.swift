import Domain
import Playback
import SwiftUI

/// The app's root once signed in: the four-tab shell, opening on In Progress. It runs the sync triggers: launch
/// (after the first frame) and return to the foreground.
public struct RootView: View {
    let library: LibraryModel
    let inProgress: InProgressModel
    let series: SeriesListModel
    let launch: LaunchSignpost?
    let covers: CoverImages?
    let downloads: DownloadsModel?
    let player: Player?
    let settings: SettingsModel?
    let listening: ListeningReporter?
    let signInAgain: SignInAgainModel?
    @State private var selection: AppTab = .inProgress
    @State private var showsSettings = false
    @Environment(\.scenePhase) private var scenePhase

    public init(
        library: LibraryModel,
        inProgress: InProgressModel,
        series: SeriesListModel,
        launch: LaunchSignpost? = nil,
        covers: CoverImages? = nil,
        downloads: DownloadsModel? = nil,
        player: Player? = nil,
        settings: SettingsModel? = nil,
        listening: ListeningReporter? = nil,
        signInAgain: SignInAgainModel? = nil
    ) {
        self.library = library
        self.inProgress = inProgress
        self.series = series
        self.launch = launch
        self.covers = covers
        self.downloads = downloads
        self.player = player
        self.settings = settings
        self.listening = listening
        self.signInAgain = signInAgain
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        Group {
                            switch tab {
                            case .inProgress:
                                InProgressView(model: inProgress, library: library, launch: launch)
                            case .library:
                                LibraryView(model: library, launch: launch)
                            case .series:
                                SeriesListView(model: series, library: library)
                            case .downloaded:
                                if let downloads {
                                    DownloadsView(model: downloads, library: library)
                                } else {
                                    ContentUnavailableView(tab.title, systemImage: tab.systemImage)
                                        .navigationTitle(tab.title)
                                }
                            }
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if let signInAgain { ConnectionBannerView(model: signInAgain) }
                        }
                        .toolbar {
                            if settings != nil {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                                }
                            }
                        }
                    }
                }
                .badge(tab == .downloaded ? downloads?.badgeCount ?? 0 : 0)
            }
        }
        .modifier(PlayerChrome(player: player))
        .sheet(isPresented: $showsSettings) {
            if let settings { SettingsView(model: settings) }
        }
        .sheet(
            isPresented: Binding(
                get: { signInAgain?.isPresented ?? false }, set: { signInAgain?.isPresented = $0 })
        ) {
            if let signInAgain { SignInAgainSheet(model: signInAgain) }
        }
        .environment(covers)
        .environment(downloads)
        .task { await signInAgain?.observe() }
        .task { await library.observe() }
        .task { await inProgress.observe() }
        .task { await series.observe() }
        .task { await covers?.observe() }
        .task { await downloads?.observe() }
        // The outbox's triggers: sends on launch, then while playing, on stops and when the network returns.
        .task { await listening?.run() }
        .task {
            // Nothing starts until the first frame is on screen. Then the file checks and the sync run side by side,
            // off the main thread (the checks in detached tasks, the sync and Downloads in their actors).
            await FrameShown.next()
            await withDiscardingTaskGroup { group in
                // A cover the check finds missing is fetched by this sync's last stage, or else the next sync.
                group.addTask { await covers?.checkFiles() }
                group.addTask {
                    // The Downloads file check before resuming, so a Download with missing files isn't treated as
                    // done; then the transfers are rebuilt from the database.
                    await downloads?.checkFiles()
                    await downloads?.resume()
                }
                group.addTask { await library.syncOnLaunch() }
            }
        }
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background {
                // Return from background → interactive: ends when the next frame is on screen.
                let returning = Signposts.begin(.returnFromBackground)
                Task {
                    await FrameShown.next()
                    returning.end()
                }
                Task { await library.syncOnForeground() }
                Task { await downloads?.resume() }
                listening?.enteredForeground()
            } else if new == .background {
                Task { await downloads?.enteredBackground() }
                listening?.enteredBackground()
            }
        }
    }
}
