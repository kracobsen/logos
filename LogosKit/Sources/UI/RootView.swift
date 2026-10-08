import SwiftUI

/// The app's root once signed in: the four-tab shell. It runs the sync triggers: launch (after the first frame) and
/// return to the foreground.
public struct RootView: View {
    let library: LibraryModel
    let launch: LaunchSignpost?
    @State private var selection: AppTab = .library
    @Environment(\.scenePhase) private var scenePhase

    public init(library: LibraryModel, launch: LaunchSignpost? = nil) {
        self.library = library
        self.launch = launch
    }

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        switch tab {
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
