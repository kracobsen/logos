// PROTOTYPE — throwaway. Variant B · One list.
// No tab bar. One navigation stack whose root is a "Continue listening" shelf (tap = play) on top of
// a single always-searchable list. Sticky filter chips scope it (All / Downloaded / In progress / …),
// a grouping menu regroups it (Books / Series / Authors). Downloads management is a toolbar sheet.
// Mini-player is a floating bar inset at the bottom; the player is full screen.

import SwiftUI

struct VariantB: View {
    @Environment(Library.self) private var library

    enum Scope: String, CaseIterable {
        case all = "All", downloaded = "Downloaded", inProgress = "In progress", notStarted = "Not started", finished = "Finished"
    }

    enum Grouping: String, CaseIterable {
        case books = "Books", series = "Series", authors = "Authors"
    }

    @State private var query = ""
    @State private var scope = Scope.all
    @State private var grouping = Grouping.books
    @State private var showsDownloads = false

    var body: some View {
        @Bindable var library = library
        let books = library.books.filter(matches).sorted { $0.sortTitle < $1.sortTitle }
        NavigationStack {
            List {
                if query.isEmpty && scope == .all {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(library.continueListening.prefix(12)) { book in
                                    ContinueCard(book: book)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Continue listening").font(.title3.bold()).foregroundStyle(.primary)
                    }
                }

                Section {
                    switch grouping {
                    case .books:
                        ForEach(books) { book in NavigationLink(value: book) { BookRow(book: book) } }
                    case .series:
                        let ids = Set(books.compactMap { $0.seriesRef?.seriesID })
                        ForEach(library.series.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }) { s in
                            NavigationLink(value: s) { SeriesRow(series: s) }
                        }
                    case .authors:
                        let byAuthor = Dictionary(grouping: books, by: \.author)
                        ForEach(byAuthor.keys.sorted(), id: \.self) { name in
                            NavigationLink(value: AuthorName(name: name)) {
                                LabeledContent(name, value: "\(byAuthor[name]!.count)")
                            }
                        }
                    }
                } header: {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Scope.allCases, id: \.self) { s in
                                Button(s.rawValue) { scope = s }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(scope == s ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial), in: .capsule)
                                    .foregroundStyle(scope == s ? .white : .primary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Logos")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, author, narrator, Series")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Group by", selection: $grouping) { ForEach(Grouping.allCases, id: \.self) { Text($0.rawValue) } }
                    } label: {
                        Label(grouping.rawValue, systemImage: "rectangle.3.group")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsDownloads = true } label: { Image(systemName: "arrow.down.circle") }
                        .badge(library.activeDownloads.count)
                }
            }
            .browseDestinations()
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayer()
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal)
        }
        .sheet(isPresented: $showsDownloads) { BDownloadsSheet() }
        .fullScreenCover(isPresented: $library.isPlayerPresented) {
            PlayerView()
                .overlay(alignment: .topTrailing) {
                    Button { library.isPlayerPresented = false } label: { Image(systemName: "chevron.down").font(.title3.bold()) }
                        .padding()
                }
        }
    }

    private func matches(_ book: Book) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let seriesName = library.series(of: book)?.name ?? ""
            guard book.title.localizedCaseInsensitiveContains(q) || book.author.localizedCaseInsensitiveContains(q)
                || book.narrator.localizedCaseInsensitiveContains(q) || seriesName.localizedCaseInsensitiveContains(q)
            else { return false }
        }
        switch scope {
        case .all: return true
        case .downloaded: return library.isDownloaded(book)
        case .inProgress: return library.isInProgress(book)
        case .notStarted: return library.progress(of: book).position == 0
        case .finished: return library.progress(of: book).finished
        }
    }
}

private struct ContinueCard: View {
    @Environment(Library.self) private var library
    let book: Book

    var body: some View {
        Button { library.play(book) } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(book: book, cornerRadius: 8)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white).shadow(radius: 3).padding(6)
                    }
                ProgressLine(fraction: library.fraction(of: book))
                Text(book.title).font(.caption.bold()).lineLimit(1)
                ListenStatus(book: book).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 130)
        }
        .buttonStyle(.plain)
        .contextMenu {
            NavigationLink(value: book) { Label("Details", systemImage: "info.circle") }
        }
    }
}

private struct BDownloadsSheet: View {
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            List {
                if !library.activeDownloads.isEmpty {
                    Section("Downloading") { ForEach(library.activeDownloads) { BookRow(book: $0) } }
                }
                Section {
                    ForEach(library.downloadedBooks.sorted { $0.sizeBytes > $1.sizeBytes }) { book in
                        LabeledContent { Text(bytes(book.sizeBytes)) } label: { BookRow(book: book) }
                            .swipeActions { Button("Remove", role: .destructive) { library.removeDownload(book) } }
                    }
                } header: {
                    Text("On this iPhone · largest first")
                } footer: {
                    Text("\(library.downloadedBooks.count) Books · \(bytes(library.downloadedBytes))")
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
