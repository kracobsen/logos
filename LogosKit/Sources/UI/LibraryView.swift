import Domain
import SwiftUI

/// The Library tab: rows in the chosen sort and filter (A–Z with a letter index by default), search revealed by
/// pulling down, a Sort and Filter menu, and a toolbar menu with Refresh and "Last updated …".
struct LibraryView: View {
    @Bindable var model: LibraryModel
    let launch: LaunchSignpost?
    @State private var opener = BookOpener()
    @State private var openedSeries: LibrarySeries?

    var body: some View {
        List {
            if !model.seriesResults.isEmpty {
                Section("Series") {
                    ForEach(model.seriesResults) { series in
                        Button {
                            openedSeries = series
                        } label: {
                            LibrarySeriesRowView(series: series)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        Button {
                            opener.open(row.id)
                        } label: {
                            LibraryRowView(row: row)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    if model.showsIndex {
                        Text(section.letter)
                    } else if model.isSearching, !model.seriesResults.isEmpty {
                        Text("Books")
                    }
                }
                .sectionIndexLabel(model.showsIndex ? section.letter : nil)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(model.showsIndex ? .visible : .hidden)
        .modifier(LetterIndexJumpSignposts())
        .searchable(
            text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Title, author, narrator or Series"
        )
        .autocorrectionDisabled()
        .overlay {
            if model.rowCount > 0, model.sections.isEmpty, model.seriesResults.isEmpty {
                if model.isSearching {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView(
                        "No \(model.filter.label) Books", systemImage: "line.3.horizontal.decrease",
                        description: Text("Choose another filter to see more of the Library."))
                }
            } else if model.rowCount == 0 {
                if model.showsFirstSync {
                    ProgressView("Syncing Library…")
                } else {
                    ContentUnavailableView(
                        "No Books yet",
                        systemImage: "books.vertical",
                        description: Text("The Library fills in when Logos can reach the Server.")
                    )
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showsFirstSync, model.rowCount > 0 {
                notice("Syncing Library…")
            } else if let message = model.refreshMessage {
                notice(message)
                    .task(id: message) { await model.dismissRefreshMessageLater() }
            }
        }
        .animation(.default, value: model.refreshMessage)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryQueryMenu(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Library options", systemImage: "ellipsis") {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isSyncing)
                    Section {
                        Text(lastUpdatedText)
                    }
                }
            }
        }
        .navigationDestination(item: $opener.opened) { route in
            BookDetailView(model: model.detail(for: route.bookID), onAppear: opener.detailAppeared)
        }
        .navigationDestination(item: $openedSeries) { series in
            SeriesPageView(model: model.seriesPage(id: series.id, name: series.name))
        }
        .onAppear { launch?.end() }
    }

    private var lastUpdatedText: String {
        guard let date = model.lastUpdated else { return "Not updated yet" }
        return "Last updated \(date.formatted(.relative(presentation: .named)))"
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.bar)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// A Series in search results: its name and how many Books it has.
struct LibrarySeriesRowView: View {
    let series: LibrarySeries

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(series.name)
                    .font(.body)
                    .lineLimit(1)
                Text(series.bookIDs.count == 1 ? "1 Book" : "\(series.bookIDs.count) Books")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the Series")
    }
}

/// One Library row: cover, title and author, bounded height.
struct LibraryRowView: View {
    let row: LibraryRow

    var body: some View {
        HStack(spacing: 12) {
            CoverView(bookID: row.id, side: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                if !row.authorName.isEmpty {
                    Text(row.authorName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.isNotOnServer {
                    NotOnServerLabel()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
