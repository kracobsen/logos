import SwiftUI

/// The app's root once signed in: the four-tab shell, opening on In Progress. It runs the sync triggers: launch
/// (after the first frame) and return to the foreground.
public struct RootView: View {
    let library: LibraryModel
    let inProgress: InProgressModel
    let series: SeriesListModel
    let launch: LaunchSignpost?
    let covers: CoverImages?
    @State private var selection: AppTab = .inProgress
    @Environment(\.scenePhase) private var scenePhase

    public init(
        library: LibraryModel,
        inProgress: InProgressModel,
        series: SeriesListModel,
        launch: LaunchSignpost? = nil,
        covers: CoverImages? = nil
    ) {
        self.library = library
        self.inProgress = inProgress
        self.series = series
        self.launch = launch
        self.covers = covers
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        switch tab {
                        case .inProgress:
                            InProgressView(model: inProgress, library: library, launch: launch)
                        case .library:
                            LibraryView(model: library, launch: launch)
                        case .series:
                            SeriesListView(model: series, library: library)
                        default:
                            ContentUnavailableView(tab.title, systemImage: tab.systemImage)
                                .navigationTitle(tab.title)
                        }
                    }
                }
            }
        }
        .environment(covers)
        .task { await library.observe() }
        .task { await inProgress.observe() }
        .task { await series.observe() }
        .task { await covers?.observe() }
        .task {
            // Let the first frame go out before any sync work starts.
            await Task.yield()
            // The cover file check first (in the background), so this sync fetches missing covers again.
            await covers?.checkFiles()
            await library.syncOnLaunch()
        }
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background {
                Task { await library.syncOnForeground() }
            }
        }
    }
}
