import SwiftUI

/// The app's root: the four-tab shell. Each tab is empty until its ticket fills it in.
public struct RootView: View {
    @State private var selection: AppTab = .library

    public init() {}

    public var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        ContentUnavailableView(tab.title, systemImage: tab.systemImage)
                            .navigationTitle(tab.title)
                    }
                }
            }
        }
    }
}

#Preview {
    RootView()
}
