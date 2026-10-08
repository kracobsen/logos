import Domain
import SwiftUI

/// A Book pushed onto a tab's navigation stack.
struct BookRoute: Hashable, Identifiable {
    let bookID: String
    var id: String { bookID }
}

/// A Series link from a Book detail. The Series page arrives with the Series tab; until then it's a placeholder.
struct SeriesRoute: Hashable {
    let seriesID: String
    let name: String
}

/// Opens Book details from a list and marks tap Book → detail with its budget signpost (≤ 100 ms): the interval
/// begins at the tap and ends when the detail appears.
@Observable
final class BookOpener {
    var opened: BookRoute?
    @ObservationIgnored private var interval: SignpostInterval?

    func open(_ bookID: String) {
        interval?.end()
        interval = Signposts.begin(.tapBookToDetail)
        opened = BookRoute(bookID: bookID)
    }

    func detailAppeared() {
        interval?.end()
        interval = nil
    }
}

/// Book detail: cover space, title, author, Series links, "duration · Chapters · size", the description and the
/// Chapter list. Everything comes from the Store, so it opens at once; a Book whose data hasn't arrived yet is
/// fetched right away.
struct BookDetailView: View {
    @State private var model: BookDetailModel
    @State private var showsFullDescription = false
    private let onAppear: () -> Void

    init(model: BookDetailModel, onAppear: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onAppear = onAppear
    }

    var body: some View {
        Group {
            if let detail = model.detail {
                content(detail)
            } else {
                ContentUnavailableView("Book not found", systemImage: "book.closed")
            }
        }
        .navigationTitle(model.detail?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SeriesRoute.self) { series in
            ContentUnavailableView(series.name, systemImage: "books.vertical")
                .navigationTitle(series.name)
        }
        .onAppear(perform: onAppear)
        .task { await model.observe() }
        .task { await model.fetchIfNeeded() }
    }

    private func content(_ detail: BookDetail) -> some View {
        List {
            Section {
                header(detail)
                    .listRowSeparator(.hidden)
            }
            if let description = model.descriptionText {
                Section {
                    Text(description)
                        .font(.body)
                        .lineLimit(showsFullDescription ? nil : 6)
                        .onTapGesture { showsFullDescription.toggle() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(showsFullDescription ? "Shows less" : "Shows the whole description")
                }
            }
            Section {
                ForEach(model.chapters) { chapter in
                    HStack {
                        Text(chapter.title)
                            .lineLimit(2)
                        Spacer()
                        Text(BookDetailModel.clock(chapter.duration))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack {
                    Text("Chapters")
                    if model.isFetching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func header(_ detail: BookDetail) -> some View {
        VStack(spacing: 12) {
            // Cover space: a solid placeholder until covers are stored.
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 220)
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
            Text(detail.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            if !detail.authorName.isEmpty {
                Text(detail.authorName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.seriesLinks) { series in
                NavigationLink(value: SeriesRoute(seriesID: series.seriesID, name: series.name)) {
                    Text(series.label)
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            Text(model.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
