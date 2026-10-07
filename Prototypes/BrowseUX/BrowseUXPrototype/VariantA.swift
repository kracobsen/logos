// PROTOTYPE — throwaway. Variant A · Tabs.
// Each way into the Library is its own tab: In Progress (most recently listened first, tap ▶ to resume),
// an A–Z Library with a section index and search built in, a Series list, and Downloaded (with
// in-flight Downloads and space used).
// A Series opens variant C's Series page (cover strip, reading order, "Continue with Book N").
// The mini-player rides above the tab bar as the tab view's bottom accessory; the player is a sheet.

import SwiftUI

struct VariantA: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        TabView {
            Tab("In Progress", systemImage: "play.circle") {
                NavigationStack { AInProgressList().aDestinations() }
            }
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack { ALibraryList().aDestinations() }
            }
            Tab("Series", systemImage: "square.stack") {
                NavigationStack { ASeriesList().aDestinations() }
            }
            Tab("Downloaded", systemImage: "arrow.down.circle") {
                NavigationStack { ADownloadedList().aDestinations() }
            }
            .badge(library.activeDownloads.count)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory { MiniPlayer() }
        .sheet(isPresented: $library.isPlayerPresented) { PlayerView() }
    }
}

private extension View {
    /// Like `browseDestinations()`, but a Series opens variant C's richer Series page.
    func aDestinations() -> some View {
        navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .navigationDestination(for: Series.self) { CSeriesView(series: $0) }
            .navigationDestination(for: AuthorName.self) { AuthorView(author: $0) }
    }
}

private struct AInProgressList: View {
    @Environment(Library.self) private var library

    var body: some View {
        let books = library.books.filter(library.isInProgress)
            .sorted { (library.progress(of: $0).lastListened ?? .distantPast) > (library.progress(of: $1).lastListened ?? .distantPast) }
        List(books) { book in
            HStack(spacing: 12) {
                NavigationLink(value: book) { BookRow(book: book) }
                Button { library.isDownloaded(book) ? library.play(book) : library.download(book) } label: {
                    Image(systemName: library.isDownloaded(book) ? "play.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .disabled(library.state(of: book) != .downloaded && library.state(of: book) != .notDownloaded)
            }
        }
        .listStyle(.plain)
        .navigationTitle("In Progress")
        .overlay { if books.isEmpty { ContentUnavailableView("Nothing in progress", systemImage: "headphones") } }
    }
}

private enum SortOrder: String, CaseIterable {
    case title = "Title", author = "Author", added = "Recently added", listened = "Recently listened"
}

private enum ListenFilter: String, CaseIterable {
    case all = "All", notStarted = "Not started", inProgress = "In progress", finished = "Finished"
}

private struct ALibraryList: View {
    @Environment(Library.self) private var library
    @State private var sort = SortOrder.title
    @State private var filter = ListenFilter.all
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let books = sorted(library.books.filter(matches))
        List {
            if !q.isEmpty {
                let results = books.filter {
                    $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q)
                        || $0.narrator.localizedCaseInsensitiveContains(q)
                        || (library.series(of: $0)?.name.localizedCaseInsensitiveContains(q) ?? false)
                }
                let series = library.series.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
                if !series.isEmpty {
                    Section("Series") {
                        ForEach(series.prefix(8)) { s in NavigationLink(value: s) { SeriesRow(series: s) } }
                    }
                }
                Section("Books · \(results.count)") {
                    ForEach(results) { book in NavigationLink(value: book) { BookRow(book: book) } }
                }
            } else if sort == .title {
                let sections = Dictionary(grouping: books) { String($0.sortTitle.prefix(1)).uppercased() }
                ForEach(sections.keys.sorted(), id: \.self) { letter in
                    Section(letter) {
                        ForEach(sections[letter]!) { book in
                            NavigationLink(value: book) { BookRow(book: book) }
                        }
                    }
                    .sectionIndexLabel(letter)
                }
            } else {
                ForEach(books) { book in
                    NavigationLink(value: book) { BookRow(book: book) }
                }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(q.isEmpty ? .visible : .hidden)
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Title, author, narrator, Series")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) { ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue) } }
                    Picker("Show", selection: $filter) { ForEach(ListenFilter.allCases, id: \.self) { Text($0.rawValue) } }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
            ToolbarItem(placement: .subtitle) { Text("\(books.count) Books").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func matches(_ book: Book) -> Bool {
        switch filter {
        case .all: true
        case .notStarted: library.progress(of: book).position == 0
        case .inProgress: library.isInProgress(book)
        case .finished: library.progress(of: book).finished
        }
    }

    private func sorted(_ books: [Book]) -> [Book] {
        switch sort {
        case .title: books.sorted { $0.sortTitle < $1.sortTitle }
        case .author: books.sorted { ($0.author, $0.sortTitle) < ($1.author, $1.sortTitle) }
        case .added: books.sorted { $0.addedAt > $1.addedAt }
        case .listened: books.sorted { (library.progress(of: $0).lastListened ?? .distantPast) > (library.progress(of: $1).lastListened ?? .distantPast) }
        }
    }
}

private struct ASeriesList: View {
    @Environment(Library.self) private var library

    var body: some View {
        List(library.series.sorted { $0.name < $1.name }) { series in
            NavigationLink(value: series) { SeriesRow(series: series) }
        }
        .listStyle(.plain)
        .navigationTitle("Series")
    }
}

private struct ADownloadedList: View {
    @Environment(Library.self) private var library

    var body: some View {
        List {
            if !library.activeDownloads.isEmpty {
                Section("Downloading") {
                    ForEach(library.activeDownloads) { book in
                        NavigationLink(value: book) { BookRow(book: book) }
                    }
                }
            }
            Section {
                ForEach(library.downloadedBooks.sorted { (library.progress(of: $0).lastListened ?? .distantPast) > (library.progress(of: $1).lastListened ?? .distantPast) }) { book in
                    NavigationLink(value: book) { BookRow(book: book) }
                        .swipeActions { Button("Remove", role: .destructive) { library.removeDownload(book) } }
                }
            } header: {
                Text("Downloaded")
            } footer: {
                Text("\(library.downloadedBooks.count) Books · \(bytes(library.downloadedBytes)) on this iPhone")
            }
        }
        .navigationTitle("Downloaded")
    }
}
