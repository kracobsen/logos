import Domain
import Playback
import SwiftUI

extension DamagedDownload {
    var headline: String {
        isNotOnServer ? DamagedText.notOnServer : DamagedText.damaged
    }

    var message: String {
        isNotOnServer
            ? "“\(title)” can't be downloaded again. Removing its Download deletes it from Logos."
            : "“\(title)” can't be played. Your position is kept; download it again to listen on."
    }
}

enum DamagedText {
    static let damaged = "This Download is damaged"
    static let notOnServer = "Damaged and no longer on the Server"
}

/// The one way out of a damaged Download: Download again, or, for a Not on Server Book, only Remove Download.
@ViewBuilder
func damagedDownloadActions(
    _ damaged: DamagedDownload, downloads: DownloadsModel?, done: @escaping () -> Void
) -> some View {
    if damaged.isNotOnServer {
        Button("Remove Download", role: .destructive) {
            done()
            Task { await downloads?.cancel(damaged.bookID) }
        }
    } else {
        Button("Download Again") {
            done()
            downloads?.startDownload(damaged.bookID)
        }
    }
    Button("Not Now", role: .cancel, action: done)
}

/// Shows the player's damaged Download, when it's found, as an alert ("This Download is damaged" with Download
/// again). `isEnabled` is off while the player sheet is up: the sheet shows it instead.
struct DamagedDownloadAlert: ViewModifier {
    let player: Player?
    let isEnabled: Bool
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?

    func body(content: Content) -> some View {
        let damaged = isEnabled ? player?.damaged : nil
        content.alert(
            damaged?.headline ?? "",
            isPresented: Binding(get: { damaged != nil }, set: { if !$0 { player?.dismissDamage() } }),
            presenting: damaged
        ) { damaged in
            damagedDownloadActions(damaged, downloads: downloads) { player?.dismissDamage() }
        } message: { damaged in
            Text(damaged.message)
        }
    }
}

/// The player sheet's content once the playing Book's Download turned out damaged mid-play.
struct DamagedDownloadView: View {
    let damaged: DamagedDownload
    let done: () -> Void
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?

    var body: some View {
        ContentUnavailableView {
            Label(damaged.headline, systemImage: "exclamationmark.triangle")
        } description: {
            Text(damaged.message)
        } actions: {
            damagedDownloadActions(damaged, downloads: downloads, done: done)
                .buttonStyle(.bordered)
        }
    }
}

/// Book detail's line (or, `compact`, an In Progress row's icon) for a Not on Server Book whose Download was found
/// damaged: it can't be downloaded again.
struct DamagedNotOnServerLabel: View {
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(DamagedText.notOnServer)
        } else {
            Label(DamagedText.notOnServer, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Book detail's Mark as Finished / Clear Finished.
struct FinishedButton: View {
    let model: BookDetailModel
    @Environment(Player.self) private var player: Player?

    var body: some View {
        if model.isFinished {
            Button("Clear Finished", systemImage: "arrow.counterclockwise") {
                model.setFinished(false, player: player)
            }
            .accessibilityHint("Moves the Book back to its start")
        } else {
            Button("Mark as Finished", systemImage: "checkmark.circle") {
                model.setFinished(true, player: player)
            }
        }
    }
}
