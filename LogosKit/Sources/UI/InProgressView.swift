import Domain
import SwiftUI

/// The In Progress tab: started, unfinished Books, most recently listened first. A row opens the Book's detail.
struct InProgressView: View {
    let model: InProgressModel
    let launch: LaunchSignpost?

    var body: some View {
        List(model.rows) { row in
            NavigationLink(value: row) {
                InProgressRowView(row: row)
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
        .navigationDestination(for: InProgressRow.self) { row in
            InProgressDetailView(row: row, progress: model.progressModel(for: row))
        }
        .onAppear { launch?.end() }
    }
}

/// One In Progress row: title, author and time left, with a thin progress line. Bounded height.
struct InProgressRowView: View {
    let row: InProgressRow

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
                    Text(timeLeftText(max(row.duration - row.position, 0)))
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

    var body: some View {
        Group {
            switch model.status {
            case .notStarted:
                Label("Not started", systemImage: "circle")
            case .inProgress(let fraction, let remaining):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    Text("\(fraction.formatted(.percent.precision(.fractionLength(0)))) · \(timeLeftText(remaining))")
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

/// The Book detail an In Progress row opens: for now its title, author and progress. Book detail proper (cover,
/// Chapters, the primary action) replaces it and embeds ``BookProgressSection``.
struct InProgressDetailView: View {
    let row: InProgressRow
    /// Kept across re-renders of the list behind, so the one being observed stays the one shown.
    @State private var progress: BookProgressModel

    init(row: InProgressRow, progress: BookProgressModel) {
        self.row = row
        _progress = State(initialValue: progress)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.title2.bold())
                    if !row.authorName.isEmpty {
                        Text(row.authorName)
                            .foregroundStyle(.secondary)
                    }
                }
                BookProgressSection(model: progress)
            }
        }
        .navigationTitle(row.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "1 hr, 5 min left", at 1×.
func timeLeftText(_ seconds: TimeInterval) -> String {
    let left = Duration.seconds(seconds.rounded())
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    return "\(left) left"
}
