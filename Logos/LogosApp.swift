import SwiftUI
import UI

/// The composition root. Modules are wired here with plain initializer injection.
@main
struct LogosApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
