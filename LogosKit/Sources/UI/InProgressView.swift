import Domain
import Playback
import SwiftUI

/// The In Progress tab: started, unfinished Books, most recently listened first. A row opens the Book's detail; its
/// trailing button starts the Book's Download, or resumes it once downloaded.
struct InProgressView: View {
    let model: InProgressModel
    /// Book details open through the Library (its Store and sync).
    let library: LibraryModel
    let launch: LaunchSignpost?
    @State private var opener = BookOpener()
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?

    var body: some View {
        List(model.rows) { row in
            HStack(spacing: 12) {
                Button {
                    opener.open(row.id)
                } label: {
                    InProgressRowView(row: row)
                }
                .foregroundStyle(.primary)
                Group {
                    if downloads?.isDamagedNotOnServer(row.id, isNotOnServer: row.isNotOnServer) == true {
                        // It can't be downloaded again: Book detail offers Remove Download.
                        DamagedNotOnServerLabel(compact: true)
                    } else {
                        // Starts the Download, or resumes a downloaded Book.
                        DownloadButton(bookID: row.id, size: 0, compact: true, resumes: true)
                            .buttonStyle(.borderless)
                    }
                }
                .frame(width: 44, height: 44)
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView(
                    "Nothing in progress",
                    systemImage: "play.circle",
                    description: Text("Books you've started show up here, most recently listened first.")
                )
            }
        }
        .navigationTitle("In Progress")
        .navigationDestination(item: $opener.opened) { route in
            BookDetailView(model: library.detail(for: route.bookID), onAppear: opener.detailAppeared)
        }
        .onAppear { launch?.end() }
    }
}

/// One In Progress row: title, author and time left (and at the speed), with a thin progress line. Bounded height.
struct InProgressRowView: View {
    let row: InProgressRow
    @Environment(Player.self) private var player: Player?

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
                if row.duration > 0 {
                    Text(timeLeftText(max(row.duration - row.position, 0), speed: player?.speed ?? 1))
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if row.duration > 0 {
                ProgressView(value: min(row.position / row.duration, 1))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Book's progress, for its detail screen: Not started, how far in and how much is left, or Finished.
struct BookProgressSection: View {
    let model: BookProgressModel
    @Environment(Player.self) private var player: Player?

    var body: some View {
        Group {
            switch model.status {
            case .notStarted:
                Label("Not started", systemImage: "circle")
            case .inProgress(let fraction, let remaining):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
                    Text("\(percent) · \(timeLeftText(remaining, speed: player?.speed ?? 1))")
                        .monospacedDigit()
                }
            case .finished:
                Label("Finished", systemImage: "checkmark.circle.fill")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .task { await model.observe() }
    }
}

/// "1 hr, 5 min left (43 min)": the time left with the wall-clock time playing it takes at `speed` in parentheses,
/// or the time left alone where the speed doesn't change it.
func timeLeftText(_ seconds: TimeInterval, speed: Double) -> String {
    let left = timeLeftText(seconds)
    guard speed > 0, speed.isFinite else { return left }
    let atSpeed = hoursAndMinutes(seconds / speed)
    return atSpeed == hoursAndMinutes(seconds) ? left : "\(left) (\(atSpeed))"
}

/// "1 hr, 5 min left", at 1×.
func timeLeftText(_ seconds: TimeInterval) -> String {
    "\(hoursAndMinutes(seconds)) left"
}

/// "1 hr, 5 min".
private func hoursAndMinutes(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds.rounded())
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
}
