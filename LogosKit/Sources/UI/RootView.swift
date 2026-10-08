import SwiftUI

/// The app's root once signed in: the four-tab shell, opening on In Progress. It runs the sync triggers: launch
/// (after the first frame) and return to the foreground.
public struct RootView: View {
    let library: LibraryModel
    let inProgress: InProgressModel
    let launch: LaunchSignpost?
    @State private var selection: AppTab = .inProgress
    @Environment(\.scenePhase) private var scenePhase

    public init(library: LibraryModel, inProgress: InProgressModel, launch: LaunchSignpost? = nil) {
        self.library = library
        self.inProgress = inProgress
        self.launch = launch
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        switch tab {
                        case .inProgress:
                            InProgressView(model: inProgress, launch: launch)
                        case .library:
                            LibraryView(model: library, launch: launch)
                        default:
                            ContentUnavailableView(tab.title, systemImage: tab.systemImage)
                                .navigationTitle(tab.title)
                        }
                    }
                }
            }
        }
        .task { await library.observe() }
        .task { await inProgress.observe() }
        .task {
            // Let the first frame go out before any sync work starts.
            await Task.yield()
            await library.syncOnLaunch()
        }
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background {
                Task { await library.syncOnForeground() }
            }
        }
    }
}
