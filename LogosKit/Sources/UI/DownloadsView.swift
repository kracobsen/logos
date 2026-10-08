import Domain
import SwiftUI

/// The Downloaded tab: the queue in FIFO order, then the downloaded Books with their sizes and the total space used.
/// A row opens the Book's detail. Queued rows can be reordered; any row can be swiped to cancel or remove its
/// Download, after one confirmation. The downloaded Books sort by recently listened or largest first.
struct DownloadsView: View {
    let model: DownloadsModel
    /// Book details open through the Library (its Store and sync).
    let library: LibraryModel
    @State private var opener = BookOpener()
    @State private var removal: DownloadRemoval?

    var body: some View {
        List {
            if let notice = model.notice {
                DownloadsNoticeView(notice: notice)
            }
            if !model.list.queue.isEmpty {
                Section("Queue") {
                    ForEach(model.list.queue) { row in
                        rowButton(row)
                            .moveDisabled(row.state != .queued)
                    }
                    .onMove { source, destination in
                        Task { await model.moveQueued(fromOffsets: source, toOffset: destination) }
                    }
                }
            }
            if !model.list.downloaded.isEmpty {
                Section {
                    ForEach(model.downloaded) { row in
                        rowButton(row)
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
        .toolbar {
            if model.list.queue.count(where: { $0.state == .queued }) > 1 {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort Downloaded Books", selection: Bindable(model).order) {
                        ForEach(DownloadedOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }
            }
        }
        .confirmsDownloadRemoval($removal, downloads: model)
    }

    private func rowButton(_ row: DownloadRow) -> some View {
        Button {
            opener.open(row.id)
        } label: {
            DownloadRowView(row: row, notice: model.notice)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            // Not the destructive role: that would take the row away before the confirmation.
            Button(row.status.isActive ? "Cancel" : "Remove", systemImage: "trash") {
                removal = DownloadRemoval(row)
            }
            .tint(.red)
        }
    }
}

/// One Downloaded row: title and author, with the size, or progress while in the queue. Bounded height.
struct DownloadRowView: View {
    let row: DownloadRow
    /// Why the queue waits, shown on waiting rows instead of "Waiting".
    var notice: DownloadsNotice?

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
            if row.isNotOnServer {
                NotOnServerLabel()
            }
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
        case .queued: notice?.text ?? "Waiting"
        case .downloading:
            notice.map { "\($0.text) · " + percent } ?? percent
        case .failed: "Failed"
        }
    }

    private var percent: String {
        row.status.fractionDone.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The Download button: Download (with size), progress with Cancel, or Play/Resume once downloaded. Book detail
/// shows it full width; In Progress rows show the compact one.
struct DownloadButton: View {
    let bookID: String
    let size: Int64
    var compact = false
    /// The listener has started the Book: a downloaded one offers Resume rather than Play.
    var resumes = false
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
                        Text(
                            "\(downloads.notice?.text ?? "Downloading") \(fraction.formatted(.percent.precision(.fractionLength(0))))"
                        )
                        .font(.subheadline)
                        .monospacedDigit()
                    }
                } else {
                    Label(downloads.notice?.text ?? "Waiting to download", systemImage: "clock")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Cancel", role: .cancel) {
                    Task { await downloads.cancel(bookID) }
                }
                .buttonStyle(.bordered)
            }
        case .downloaded:
            PlayButton(bookID: bookID, resumes: resumes)
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
            PlayButton(bookID: bookID, resumes: resumes, compact: true)
        }
    }
}
