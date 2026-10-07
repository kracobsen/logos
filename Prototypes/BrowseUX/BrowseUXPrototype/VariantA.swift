// PROTOTYPE — throwaway. Variant A · Tabs.
// Each way into the Library is its own tab: an A–Z Library with a section index, a Series list,
// Downloaded (with in-flight Downloads and space used), and a system Search tab.
// The mini-player rides above the tab bar as the tab view's bottom accessory; the player is a sheet.

import SwiftUI

struct VariantA: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack { ALibraryList().browseDestinations() }
            }
            Tab("Series", systemImage: "square.stack") {
                NavigationStack { ASeriesList().browseDestinations() }
            }
            Tab("Downloaded", systemImage: "arrow.down.circle") {
                NavigationStack { ADownloadedList().browseDestinations() }
            }
            .badge(library.activeDownloads.count)
            Tab(role: .search) {
                NavigationStack { ASearch().browseDestinations() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory { MiniPlayer() }
        .sheet(isPresented: $library.isPlayerPresented) { PlayerView() }
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

    var body: some View {
        let books = sorted(library.books.filter(matches))
        List {
            if sort == .title {
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
        .listSectionIndexVisibility(.visible)
        .navigationTitle("Library")
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

private struct ASearch: View {
    @Environment(Library.self) private var library
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        List {
            if q.isEmpty {
                Section("Recently added") {
                    ForEach(library.books.sorted { $0.addedAt > $1.addedAt }.prefix(15)) { book in
                        NavigationLink(value: book) { BookRow(book: book) }
                    }
                }
            } else {
                let series = library.series.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
                let books = library.books.filter {
                    $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) || $0.narrator.localizedCaseInsensitiveContains(q)
                }
                if !series.isEmpty {
                    Section("Series") {
                        ForEach(series.prefix(8)) { s in NavigationLink(value: s) { SeriesRow(series: s) } }
                    }
                }
                Section("Books · \(books.count)") {
                    ForEach(books) { book in NavigationLink(value: book) { BookRow(book: book) } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Title, author, narrator, Series")
    }
}
