// PROTOTYPE — throwaway. Variant C · Cover shelf.
// A cover grid where every Series collapses into one stacked tile (so ~1000 Books become far fewer
// tiles), standalone Books are single tiles. A toolbar toggle flips the whole shelf to downloaded-only.
// Long-press any tile for Play / Download / Go to Series. Series open as a rich page with the reading
// order as big numbers. Mini-player floats as a capsule; the player is a resizable sheet.

import SwiftUI

private enum Tile: Identifiable {
    case book(Book), series(Series, [Book])

    var id: String {
        switch self {
        case .book(let b): "b\(b.id)"
        case .series(let s, _): "s\(s.id)"
        }
    }
}

struct VariantC: View {
    @Environment(Library.self) private var library

    enum Sort: String, CaseIterable { case listened = "Recently listened", title = "Title", added = "Recently added", author = "Author" }

    @State private var query = ""
    @State private var downloadedOnly = false
    @State private var sort = Sort.listened

    var body: some View {
        @Bindable var library = library
        let tiles = makeTiles()
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], alignment: .leading, spacing: 20) {
                    ForEach(tiles) { tile in
                        switch tile {
                        case .book(let book):
                            NavigationLink(value: book) { BookTile(book: book) }
                                .buttonStyle(.plain)
                                .contextMenu { bookMenu(book) }
                        case .series(let series, let books):
                            NavigationLink(value: series) { SeriesTile(series: series, books: books) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if let next = library.nextUp(in: series) { bookMenu(next) }
                                }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 90)
            }
            .navigationTitle(downloadedOnly ? "Downloaded" : "Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { downloadedOnly.toggle() } label: {
                        Image(systemName: downloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .subtitle) {
                    Text(downloadedOnly ? "\(library.downloadedBooks.count) Books · \(bytes(library.downloadedBytes))" : "\(library.books.count) Books · \(library.series.count) Series")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Title, author, narrator, Series")
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .navigationDestination(for: Series.self) { CSeriesView(series: $0) }
            .navigationDestination(for: AuthorName.self) { AuthorView(author: $0) }
        }
        .overlay(alignment: .bottom) {
            MiniPlayer()
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
        }
        .sheet(isPresented: $library.isPlayerPresented) {
            PlayerView().presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func bookMenu(_ book: Book) -> some View {
        if library.isDownloaded(book) {
            Button { library.play(book) } label: { Label("Play \(book.title)", systemImage: "play.fill") }
        } else if library.state(of: book) == .notDownloaded {
            Button { library.download(book) } label: { Label("Download \(book.title)", systemImage: "arrow.down.circle") }
        }
        if let s = library.series(of: book) {
            NavigationLink(value: s) { Label("Go to \(s.name)", systemImage: "square.stack") }
        }
    }

    private func makeTiles() -> [Tile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let books = library.books.filter { book in
            if downloadedOnly && library.state(of: book) == .notDownloaded { return false }
            guard !q.isEmpty else { return true }
            return book.title.localizedCaseInsensitiveContains(q) || book.author.localizedCaseInsensitiveContains(q)
                || book.narrator.localizedCaseInsensitiveContains(q) || (library.series(of: book)?.name.localizedCaseInsensitiveContains(q) ?? false)
        }
        var tiles: [Tile] = []
        var seen = Set<Int>()
        for book in books {
            guard let sid = book.seriesRef?.seriesID else { tiles.append(.book(book)); continue }
            guard seen.insert(sid).inserted, let s = library.seriesByID[sid] else { continue }
            let members = library.books(in: s).filter { m in books.contains { $0.id == m.id } }
            tiles.append(members.count == 1 ? .book(members[0]) : .series(s, members))
        }
        return tiles.sorted { key($0) < key($1) }
    }

    private func key(_ tile: Tile) -> String {
        let books: [Book] = switch tile {
        case .book(let b): [b]
        case .series(_, let bs): bs
        }
        switch sort {
        case .title:
            if case .series(let s, _) = tile { return s.name.replacingOccurrences(of: "The ", with: "") }
            return books[0].sortTitle
        case .author: return books[0].author
        case .added: return String(format: "%020.0f", 1e12 - (books.map(\.addedAt).max()!.timeIntervalSince1970))
        case .listened:
            let last = books.compactMap { library.progress(of: $0).lastListened }.max() ?? .distantPast
            return String(format: "%020.0f", 1e12 - last.timeIntervalSince1970)
        }
    }
}

private struct BookTile: View {
    @Environment(Library.self) private var library
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverView(book: book)
                .overlay(alignment: .topTrailing) {
                    DownloadBadge(state: library.state(of: book))
                        .padding(4).background(.ultraThinMaterial, in: .circle).padding(4)
                        .opacity(library.state(of: book) == .notDownloaded ? 0 : 1)
                }
                .overlay(alignment: .bottom) {
                    if library.isInProgress(book) { ProgressLine(fraction: library.fraction(of: book)).padding(5) }
                }
                .opacity(library.progress(of: book).finished ? 0.55 : 1)
            Text(book.title).font(.caption.weight(.medium)).lineLimit(2)
        }
    }
}

private struct SeriesTile: View {
    let series: Series
    let books: [Book]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.offset) { i, book in
                    CoverView(book: book)
                        .scaleEffect(1 - CGFloat(i) * 0.08)
                        .offset(y: -CGFloat(i) * 7)
                        .shadow(radius: 1.5)
                }
            }
            .padding(.top, 14)
            .overlay(alignment: .bottomTrailing) {
                Text("\(books.count)").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: .capsule).foregroundStyle(.white).padding(5)
            }
            Text(series.name).font(.caption.weight(.semibold)).lineLimit(2)
        }
    }
}

struct CSeriesView: View {
    @Environment(Library.self) private var library
    let series: Series

    var body: some View {
        let books = library.books(in: series)
        let next = library.nextUp(in: series)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(books) { book in
                            NavigationLink(value: book) {
                                CoverView(book: book, cornerRadius: 8).frame(width: 150)
                                    .overlay(alignment: .topLeading) {
                                        Text(book.seriesRef?.label ?? "").font(.headline).padding(6)
                                            .background(.ultraThinMaterial, in: .rect(cornerRadius: 6)).padding(6)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 4) {
                    NavigationLink(value: AuthorName(name: series.author)) { Text(series.author).font(.headline) }
                    Text("\(books.count) Books · \(hoursMinutes(books.reduce(0) { $0 + $1.duration })) · \(books.filter { library.progress(of: $0).finished }.count) finished")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                if let next {
                    Button {
                        if library.isDownloaded(next) { library.play(next) } else { library.download(next) }
                    } label: {
                        Label(library.isDownloaded(next) ? "Continue with Book \(next.seriesRef?.label ?? "")" : "Download Book \(next.seriesRef?.label ?? "") to continue",
                              systemImage: library.isDownloaded(next) ? "play.fill" : "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.horizontal)
                }

                VStack(spacing: 0) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            HStack(alignment: .center, spacing: 14) {
                                Text(book.seriesRef?.label ?? "").font(.largeTitle.bold().monospacedDigit())
                                    .foregroundStyle(book.id == next?.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                    .frame(width: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(book.title).font(.headline)
                                    HStack { ListenStatus(book: book); DownloadBadge(state: library.state(of: book)) }
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10).padding(.horizontal)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 86)
                    }
                }
            }
            .padding(.bottom, 90)
        }
        .navigationTitle(series.name)
    }
}
