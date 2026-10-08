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
    let settings: SettingsModel?
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
        settings: SettingsModel? = nil
    ) {
        self.library = library
        self.inProgress = inProgress
        self.series = series
        self.launch = launch
        self.covers = covers
        self.downloads = downloads
        self.settings = settings
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
        .sheet(isPresented: $showsSettings) {
            if let settings { SettingsView(model: settings) }
        }
        .environment(covers)
        .environment(downloads)
        .task { await library.observe() }
        .task { await inProgress.observe() }
        .task { await series.observe() }
        .task { await covers?.observe() }
        .task { await downloads?.observe() }
        .task {
            // Let the first frame go out before any sync work starts.
            await Task.yield()
            // The cover file check first (in the background), so this sync fetches missing covers again.
            await covers?.checkFiles()
            // Rebuild the Download transfers from the database, alongside the launch sync.
            async let downloadsResumed: Void = downloads?.resume() ?? ()
            await library.syncOnLaunch()
            await downloadsResumed
        }
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background {
                Task { await library.syncOnForeground() }
                Task { await downloads?.resume() }
            } else if new == .background {
                Task { await downloads?.enteredBackground() }
            }
        }
    }
}
