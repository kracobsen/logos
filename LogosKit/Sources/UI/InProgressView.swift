import Domain
import SwiftUI

/// The In Progress tab: started, unfinished Books, most recently listened first. A row opens the Book's detail.
struct InProgressView: View {
    let model: InProgressModel
    /// Book details open through the Library (its Store and sync).
    let library: LibraryModel
    let launch: LaunchSignpost?
    @State private var opener = BookOpener()

    var body: some View {
        List(model.rows) { row in
            Button {
                opener.open(row.id)
            } label: {
                InProgressRowView(row: row)
            }
            .foregroundStyle(.primary)
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

/// "1 hr, 5 min left", at 1×.
func timeLeftText(_ seconds: TimeInterval) -> String {
    let left = Duration.seconds(seconds.rounded())
        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    return "\(left) left"
}
