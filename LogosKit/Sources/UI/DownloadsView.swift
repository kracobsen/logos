import Domain
import SwiftUI

/// The Downloaded tab: the queue in FIFO order, then the downloaded Books with their sizes and the total space used.
/// A row opens the Book's detail.
struct DownloadsView: View {
    let model: DownloadsModel
    /// Book details open through the Library (its Store and sync).
    let library: LibraryModel
    @State private var opener = BookOpener()

    var body: some View {
        List {
            if !model.list.queue.isEmpty {
                Section("Queue") {
                    ForEach(model.list.queue) { row in
                        Button {
                            opener.open(row.id)
                        } label: {
                            DownloadRowView(row: row)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            if !model.list.downloaded.isEmpty {
                Section {
                    ForEach(model.list.downloaded) { row in
                        Button {
                            opener.open(row.id)
                        } label: {
                            DownloadRowView(row: row)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Downloaded")
                } footer: {
                    Text("\(model.totalSize) used")
                }
            }
        }
        .overlay {
            if model.list.queue.isEmpty, model.list.downloaded.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download a Book from its detail to listen to it.")
                )
            }
        }
        .navigationTitle("Downloaded")
        .navigationDestination(item: $opener.opened) { route in
            BookDetailView(model: library.detail(for: route.bookID), onAppear: opener.detailAppeared)
        }
    }
}

/// One Downloaded row: title and author, with the size, or progress while in the queue. Bounded height.
struct DownloadRowView: View {
    let row: DownloadRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.body)
                .lineLimit(1)
            HStack {
                if !row.authorName.isEmpty {
                    Text(row.authorName)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(detail)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if row.state == .downloading {
                ProgressView(value: row.status.fractionDone)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch row.state {
        case .downloaded: DownloadsModel.size(row.totalBytes)
        case .queued: "Waiting"
        case .downloading: row.status.fractionDone.formatted(.percent.precision(.fractionLength(0)))
        case .failed: "Failed"
        }
    }
}

/// The Download button: Download (with size), progress with Cancel, or Downloaded. Book detail shows it full width;
/// In Progress rows show the compact one.
struct DownloadButton: View {
    let bookID: String
    let size: Int64
    var compact = false
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?

    var body: some View {
        if let downloads {
            let action = downloads.action(forBook: bookID, size: size)
            if compact {
                compactButton(action, downloads)
            } else {
                fullButton(action, downloads)
            }
        }
    }

    @ViewBuilder
    private func fullButton(_ action: BookDownloadAction, _ downloads: DownloadsModel) -> some View {
        switch action {
        case .download(let label):
            Button {
                downloads.startDownload(bookID)
            } label: {
                Label(label, systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .queued, .downloading:
            HStack(spacing: 12) {
                if case .downloading(let fraction) = action {
                    ProgressView(value: fraction) {
                        Text("Downloading \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                } else {
                    Label("Waiting to download", systemImage: "clock")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Cancel", role: .cancel) {
                    Task { await downloads.cancel(bookID) }
                }
                .buttonStyle(.bordered)
            }
        case .downloaded:
            // Playback makes this Play/Resume.
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .failed:
            Button {
                downloads.startDownload(bookID)
            } label: {
                Label("Download failed · Try again", systemImage: "exclamationmark.arrow.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func compactButton(_ action: BookDownloadAction, _ downloads: DownloadsModel) -> some View {
        switch action {
        case .download, .failed:
            Button {
                downloads.startDownload(bookID)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
            }
            .accessibilityLabel("Download")
        case .queued:
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Waiting to download")
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .accessibilityLabel("Downloading")
        case .downloaded:
            // Playback (#30) makes this resume the Book.
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityLabel("Downloaded")
        }
    }
}
