// PROTOTYPE — throwaway. Answers wayfinder ticket "Prototype: browse and navigation UX"
// (https://github.com/kracobsen/logos/issues/11).
//
// Three structurally different navigation variants for browsing a ~1000-Book Library on fake data,
// switchable from the yellow pill at the top. The choice persists across launches (UserDefaults key
// "variant"); `-variant B` as a launch argument overrides it.
//
//   A · Tabs          — tab bar: Library / Series / Downloaded / Search, mini-player as tab accessory
//   B · One list      — single stack: Continue listening shelf + one searchable list with filter chips
//   C · Cover shelf   — cover grid where each Series collapses to one tile; downloaded-only toggle

import SwiftUI

@main
struct BrowseUXPrototypeApp: App {
    @State private var library = Library()
    @AppStorage("variant") private var variant = "A"

    private let variants = [(key: "A", name: "Tabs"), (key: "B", name: "One list"), (key: "C", name: "Cover shelf")]

    var body: some Scene {
        WindowGroup {
            Group {
                switch variant {
                case "B": VariantB()
                case "C": VariantC()
                default: VariantA()
                }
            }
            .id(variant)
            .environment(library)
            #if DEBUG
            .overlay(alignment: .top) {
                PrototypeSwitcher(current: $variant, variants: variants).padding(.top, 2)
            }
            #endif
        }
    }
}
