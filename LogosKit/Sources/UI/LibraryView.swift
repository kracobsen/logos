import Domain
import SwiftUI

/// The Library tab: rows A–Z with a letter index, and a toolbar menu with Refresh and "Last updated …".
struct LibraryView: View {
    let model: LibraryModel
    let launch: LaunchSignpost?
    @State private var opener = BookOpener()

    var body: some View {
        List {
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
                    Text(section.letter)
                }
                .sectionIndexLabel(section.letter)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .overlay {
            if model.rowCount == 0 {
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
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        model.dismissRefreshMessage()
                    }
            }
        }
        .animation(.default, value: model.refreshMessage)
        .navigationTitle("Library")
        .toolbar {
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

/// One Library row: title and author, bounded height.
struct LibraryRowView: View {
    let row: LibraryRow

    var body: some View {
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
        }
        .accessibilityElement(children: .combine)
    }
}
