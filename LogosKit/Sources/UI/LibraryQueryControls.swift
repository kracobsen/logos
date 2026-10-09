import Domain
import SwiftUI

extension LibrarySort {
    var label: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .recentlyAdded: "Recently Added"
        case .recentlyListened: "Recently Listened"
        }
    }
}

extension LibraryFilter {
    var label: String {
        switch self {
        case .all: "All"
        case .notStarted: "Not Started"
        case .inProgress: "In Progress"
        case .finished: "Finished"
        }
    }
}

/// The Library's Sort and Filter menu.
struct LibraryQueryMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Menu("Sort and filter", systemImage: "line.3.horizontal.decrease") {
            Picker("Sort", selection: $model.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { Text($0.label) }
            }
            .pickerStyle(.inline)
            Picker("Filter", selection: $model.filter) {
                ForEach(LibraryFilter.allCases, id: \.self) { Text($0.label) }
            }
            .pickerStyle(.inline)
        }
    }
}

/// Marks letter-index jumps with the `.letterIndexJump` signpost.
///
/// SwiftUI's section index has no callback, so a jump is recognised from the scroll geometry: the offset moves by
/// more than a screen while no scroll is running (no drag, deceleration or animation) and the content keeps its
/// height (so a sort, filter or search change doesn't count). The interval runs from that update until the main
/// queue's next turn, after the jumped-to rows are laid out and committed. The finger-down-to-offset part happens
/// inside UIKit and isn't covered.
struct LetterIndexJumpSignposts: ViewModifier {
    struct Probe: Equatable {
        let offset: CGFloat
        let viewport: CGFloat
        let contentHeight: CGFloat
    }

    @State private var phase: ScrollPhase = .idle

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in phase = newPhase }
            .onScrollGeometryChange(for: Probe.self) { geometry in
                Probe(
                    offset: geometry.contentOffset.y, viewport: geometry.containerSize.height,
                    contentHeight: geometry.contentSize.height)
            } action: { old, new in
                guard phase == .idle, old.contentHeight == new.contentHeight, new.viewport > 0,
                    abs(new.offset - old.offset) > new.viewport
                else { return }
                let interval = Signposts.begin(.letterIndexJump)
                DispatchQueue.main.async { interval.end() }
            }
    }
}
