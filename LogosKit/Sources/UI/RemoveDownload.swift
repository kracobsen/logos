import Domain
import SwiftUI

/// A Download the listener asked to remove (or cancel), waiting for the one confirmation.
struct DownloadRemoval: Identifiable, Hashable {
    let bookID: String
    let title: String
    let isNotOnServer: Bool
    /// Still queued or downloading: this cancels it.
    let isActive: Bool

    var id: String { bookID }

    init(bookID: String, title: String, isNotOnServer: Bool, isActive: Bool) {
        self.bookID = bookID
        self.title = title
        self.isNotOnServer = isNotOnServer
        self.isActive = isActive
    }

    init(_ row: DownloadRow) {
        self.init(bookID: row.id, title: row.title, isNotOnServer: row.isNotOnServer, isActive: row.status.isActive)
    }

    var dialogTitle: String { isActive ? "Cancel the Download of “\(title)”?" : "Remove the Download of “\(title)”?" }

    var buttonTitle: String {
        if isActive { return "Cancel Download" }
        return isNotOnServer ? "Remove Download and Book" : "Remove Download"
    }

    var message: String {
        if isNotOnServer {
            return "This Book is no longer on the Server, so removing its Download deletes it from Logos."
        }
        return "Its files are deleted from this iPhone. Your progress and the Book stay in your Library."
    }
}

extension View {
    /// Asks once before removing or cancelling `removal`'s Download, then does it.
    func confirmsDownloadRemoval(
        _ removal: Binding<DownloadRemoval?>,
        downloads: DownloadsModel?,
        onRemoved: @escaping (DownloadRemoval) -> Void = { _ in }
    ) -> some View {
        confirmationDialog(
            removal.wrappedValue?.dialogTitle ?? "",
            isPresented: Binding(get: { removal.wrappedValue != nil }, set: { if !$0 { removal.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: removal.wrappedValue
        ) { pending in
            Button(pending.buttonTitle, role: .destructive) {
                Task {
                    await downloads?.cancel(pending.bookID)
                    onRemoved(pending)
                }
            }
        } message: { pending in
            Text(pending.message)
        }
    }
}

/// Book detail's Remove Download, at the bottom: shown once the Book has a Download that isn't queued or downloading
/// (those have Cancel on the primary action). Removing a Not on Server Book closes the detail.
struct RemoveDownloadButton: View {
    let detail: BookDetail
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?
    @Environment(\.dismiss) private var dismiss
    @State private var removal: DownloadRemoval?

    var body: some View {
        if let status = downloads?.status(of: detail.id), !status.isActive {
            Button("Remove Download", systemImage: "trash", role: .destructive) {
                removal = DownloadRemoval(
                    bookID: detail.id, title: detail.title, isNotOnServer: detail.isNotOnServer, isActive: false)
            }
            .confirmsDownloadRemoval($removal, downloads: downloads) { removed in
                if removed.isNotOnServer { dismiss() }
            }
        }
    }
}

/// The Not on Server marker.
struct NotOnServerLabel: View {
    var body: some View {
        Label("Not on Server", systemImage: "icloud.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
