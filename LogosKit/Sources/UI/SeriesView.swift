import Domain
import SwiftUI

/// The Series tab: every Series A–Z. A Series opens its page.
struct SeriesListView: View {
    let model: SeriesListModel
    /// Series pages and Book details open through the Library (its Store and sync).
    let library: LibraryModel
    @State private var opened: SeriesSummary?

    var body: some View {
        List(model.series) { series in
            Button {
                opened = series
            } label: {
                HStack {
                    Text(series.name)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(series.bookCount == 1 ? "1 Book" : "\(series.bookCount) Books")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
        .overlay {
            if model.series.isEmpty {
                ContentUnavailableView(
                    "No Series",
                    systemImage: "square.stack",
                    description: Text("Series show up here once the Library has synced.")
                )
            }
        }
        .navigationTitle("Series")
        .navigationDestination(item: $opened) { series in
            SeriesPageView(model: library.seriesPage(id: series.id, name: series.name))
        }
    }
}

/// A Series page: a strip of covers, the reading order as big sequence numbers (exactly as the Server gives them),
/// and one button: "Continue with Book N" or "Download Book N to continue".
struct SeriesPageView: View {
    @State private var model: SeriesPageModel
    @State private var opener = BookOpener()

    init(model: SeriesPageModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                coverStrip
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                if let target = model.continueTarget {
                    Button {
                        if let bookID = model.continueTapped() { opener.open(bookID) }
                    } label: {
                        Label(
                            target.label,
                            systemImage: target.action == .play ? "play.fill" : "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(model.books) { book in
                    Button {
                        opener.open(book.id)
                    } label: {
                        SeriesBookRow(book: book, isNext: book.id == model.continueTarget?.book.id)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.books.isEmpty {
                ContentUnavailableView(model.name, systemImage: "square.stack")
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opener.opened) { route in
            BookDetailView(model: model.detail(for: route.bookID), onAppear: opener.detailAppeared)
        }
        .task { await model.observe() }
    }

    private var coverStrip: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(model.books) { book in
                    Button {
                        opener.open(book.id)
                    } label: {
                        CoverView(bookID: book.id, side: 120, cornerRadius: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(book.title)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }
}

/// One Book on a Series page: its sequence as a big number, title, and Finished or In Progress. Bounded height.
struct SeriesBookRow: View {
    let book: SeriesBook
    /// It's the Continue button's target.
    let isNext: Bool

    var body: some View {
        HStack(spacing: 16) {
            Text(book.sequence ?? "–")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(isNext ? Color.accentColor : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                    .lineLimit(2)
                if book.isFinished {
                    Label("Finished", systemImage: "checkmark.circle.fill")
                } else if book.position > 0 {
                    Label("In Progress", systemImage: "circle.lefthalf.filled")
                } else if let year = book.publishedYear {
                    Text(year)
                }
            }
            .font(.subheadline)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
