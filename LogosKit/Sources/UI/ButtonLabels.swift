import SwiftUI

/// A full-width button's icon and title, centred together. (A `Label` here leaves its icon undrawn but keeps its
/// space, which pushes the title off centre.)
struct WideButtonLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// The look of Book detail's icon buttons beside the primary button.
    func bookDetailIcon() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
    }
}
