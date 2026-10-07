// PROTOTYPE — throwaway. Pieces the variants share: cover art, rows, Book detail, player stub, switcher.

import SwiftUI

// MARK: - Formatting

func hoursMinutes(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

// MARK: - Cover

struct CoverView: View {
    let book: Book
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(LinearGradient(
                colors: [Color(hue: book.hue, saturation: 0.55, brightness: 0.75), Color(hue: book.hue, saturation: 0.8, brightness: 0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.system(size: max(5, geo.size.width * 0.11), weight: .bold, design: .serif))
                        Text(book.author).font(.system(size: max(4, geo.size.width * 0.07)))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(geo.size.width * 0.08)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
    }
}

struct StackedCovers: View {
    let books: [Book]
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.offset) { i, book in
                CoverView(book: book, cornerRadius: 4)
                    .frame(width: size - CGFloat(i) * 6)
                    .offset(x: CGFloat(i) * 7)
                    .shadow(radius: 1)
            }
        }
        .frame(width: size + 14, height: size, alignment: .leading)
    }
}

// MARK: - Status

struct DownloadBadge: View {
    let state: DownloadState

    var body: some View {
        switch state {
        case .notDownloaded: EmptyView()
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading(let f):
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2.5)
                Circle().trim(from: 0, to: f).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
        case .downloaded: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
        }
    }
}

struct ProgressLine: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

/// "4h 12m left", "Finished", or the total duration.
struct ListenStatus: View {
    @Environment(Library.self) private var library
    let book: Book

    var body: some View {
        let p = library.progress(of: book)
        if p.finished {
            Label("Finished", systemImage: "checkmark").labelStyle(.titleAndIcon)
        } else if p.position > 0 {
            Text("\(hoursMinutes(book.duration - p.position)) left")
        } else {
            Text(hoursMinutes(book.duration))
        }
    }
}

// MARK: - Rows

struct BookRow: View {
    @Environment(Library.self) private var library
    let book: Book
    var showsSeries = true

    var body: some View {
        HStack(spacing: 12) {
            CoverView(book: book, cornerRadius: 4).frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                if showsSeries, let s = library.series(of: book), let ref = book.seriesRef {
                    Text("\(s.name) · \(ref.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    ListenStatus(book: book)
                    if library.isInProgress(book) { ProgressLine(fraction: library.fraction(of: book)).frame(width: 50) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            DownloadBadge(state: library.state(of: book))
        }
    }
}

struct SeriesRow: View {
    @Environment(Library.self) private var library
    let series: Series

    var body: some View {
        let books = library.books(in: series)
        HStack(spacing: 12) {
            StackedCovers(books: books, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(series.name).font(.headline).lineLimit(2)
                Text(series.author).font(.subheadline).foregroundStyle(.secondary)
                Text("\(books.count) Books · \(books.filter { library.progress(of: $0).finished }.count) finished · \(books.filter(library.isDownloaded).count) downloaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Book detail

struct BookDetailView: View {
    @Environment(Library.self) private var library
    let book: Book

    var body: some View {
        let state = library.state(of: book)
        List {
            Section {
                VStack(spacing: 10) {
                    CoverView(book: book, cornerRadius: 10).frame(width: 200).shadow(radius: 8)
                    Text(book.title).font(.title2.bold()).multilineTextAlignment(.center)
                    NavigationLink(value: AuthorName(name: book.author)) { Text(book.author).font(.headline) }
                        .buttonStyle(.plain).foregroundStyle(.tint)
                    Text("Narrated by \(book.narrator)").font(.subheadline).foregroundStyle(.secondary)
                    if let s = library.series(of: book), let ref = book.seriesRef {
                        NavigationLink(value: s) {
                            Label("\(s.name), Book \(ref.label)", systemImage: "square.stack")
                        }
                        .buttonStyle(.bordered).font(.subheadline)
                    }
                    HStack(spacing: 16) {
                        Label(hoursMinutes(book.duration), systemImage: "clock")
                        Label("\(book.chapters.count) Chapters", systemImage: "list.bullet")
                        Label(bytes(book.sizeBytes), systemImage: "internaldrive")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ListenStatus(book: book).font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                switch state {
                case .downloaded:
                    Button {
                        library.play(book)
                    } label: {
                        Label(library.isInProgress(book) ? "Resume" : "Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .listRowBackground(Color.clear)
                case .notDownloaded:
                    Button {
                        library.download(book)
                    } label: {
                        Label("Download · \(bytes(book.sizeBytes))", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .listRowBackground(Color.clear)
                case .queued:
                    LabeledContent("Waiting to download") { Button("Cancel", role: .destructive) { library.removeDownload(book) } }
                case .downloading(let f):
                    VStack(alignment: .leading) {
                        LabeledContent("Downloading \(Int(f * 100))%") { Button("Cancel", role: .destructive) { library.removeDownload(book) } }
                        ProgressView(value: f)
                    }
                }
            } footer: {
                if state != .downloaded { Text("Only downloaded Books can be played.") }
            }

            Section("Chapters") {
                ForEach(book.chapters) { chapter in
                    Button {
                        library.play(book, from: chapter)
                    } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(state == .downloaded ? .primary : .secondary)
                            Spacer()
                            Text(hoursMinutes(chapter.duration)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .disabled(state != .downloaded)
                }
            }

            Section("About") { Text(book.blurb) }

            if state == .downloaded {
                Section { Button("Remove Download", role: .destructive) { library.removeDownload(book) } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Series detail (plain, used by variants A and B)

struct SeriesDetailView: View {
    @Environment(Library.self) private var library
    let series: Series

    var body: some View {
        let books = library.books(in: series)
        List {
            Section {
                HStack(spacing: 14) {
                    StackedCovers(books: books, size: 90)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(series.author).font(.headline)
                        Text("\(books.count) Books · \(hoursMinutes(books.reduce(0) { $0 + $1.duration }))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let next = library.nextUp(in: series) {
                    NavigationLink(value: next) {
                        Label("Up next: Book \(next.seriesRef?.label ?? "") — \(next.title)", systemImage: "arrow.forward.circle")
                    }
                }
            }
            Section("In order") {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        HStack(spacing: 10) {
                            Text(book.seriesRef?.label ?? "").font(.title3.bold().monospacedDigit()).frame(width: 34)
                            BookRow(book: book, showsSeries: false)
                        }
                    }
                }
            }
        }
        .navigationTitle(series.name)
    }
}

struct AuthorView: View {
    @Environment(Library.self) private var library
    let author: AuthorName

    var body: some View {
        List(library.books.filter { $0.author == author.name }) { book in
            NavigationLink(value: book) { BookRow(book: book) }
        }
        .navigationTitle(author.name)
    }
}

extension View {
    /// Push destinations shared by variants A and B.
    func browseDestinations() -> some View {
        navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            .navigationDestination(for: AuthorName.self) { AuthorView(author: $0) }
    }
}

// MARK: - Player stub

struct PlayerView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showsChapters = false

    var body: some View {
        if let book = library.nowPlaying {
            let chapter = library.currentChapter(of: book)
            let position = library.progress(of: book).position
            VStack(spacing: 18) {
                Capsule().fill(.tertiary).frame(width: 40, height: 5).padding(.top, 8)
                CoverView(book: book, cornerRadius: 12).frame(maxWidth: 300).shadow(radius: 12)
                VStack(spacing: 4) {
                    Text(book.title).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(book.author).foregroundStyle(.secondary)
                }
                Button { showsChapters = true } label: {
                    Label(chapter.title, systemImage: "list.bullet").font(.subheadline)
                }
                .buttonStyle(.bordered)

                VStack(spacing: 4) {
                    Slider(value: Binding(get: { position - chapter.start }, set: { library.seek(to: chapter.start + $0) }), in: 0...chapter.duration)
                    HStack {
                        Text(clock(position - chapter.start))
                        Spacer()
                        Text("−\(clock((chapter.start + chapter.duration - position) / library.speed))")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                HStack(spacing: 44) {
                    Button { library.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { library.isPlaying.toggle() } label: {
                        Image(systemName: library.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 48))
                    }
                    Button { library.skip(30) } label: { Image(systemName: "goforward.30") }
                }
                .font(.system(size: 30))

                HStack {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                            Button(String(format: "%g×", s)) { library.speed = s }
                        }
                    } label: { Text(String(format: "%g×", library.speed)).bold() }
                    Spacer()
                    Menu {
                        Button("End of this Chapter") {}
                        ForEach(2...5, id: \.self) { n in Button("End of \(n) Chapters") {} }
                    } label: { Image(systemName: "moon.zzz") }
                }
                .font(.title3)
                Text("\(hoursMinutes((book.duration - position) / library.speed)) left in Book").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .sheet(isPresented: $showsChapters) {
                NavigationStack {
                    List(book.chapters) { c in
                        Button {
                            library.seek(to: c.start)
                            showsChapters = false
                        } label: {
                            HStack {
                                Text(c.title).fontWeight(c.id == chapter.id ? .bold : .regular)
                                Spacer()
                                Text(hoursMinutes(c.duration)).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                    .navigationTitle("Chapters")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        } else {
            ContentUnavailableView("Nothing playing", systemImage: "headphones")
        }
    }
}

/// Compact now-playing bar. Variants decide where it sits and how it opens the player.
struct MiniPlayer: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let book = library.nowPlaying {
            HStack(spacing: 10) {
                CoverView(book: book, cornerRadius: 4).frame(width: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(book.title).font(.subheadline.bold()).lineLimit(1)
                    Text(library.currentChapter(of: book).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { library.isPlaying.toggle() } label: {
                    Image(systemName: library.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                Button { library.skip(30) } label: { Image(systemName: "goforward.30").font(.title3) }
            }
            .padding(.horizontal, 14)
            .contentShape(.rect)
            .onTapGesture { library.isPlayerPresented = true }
            .tint(.primary)
        }
    }
}

// MARK: - Prototype switcher (never part of the design being judged)

struct PrototypeSwitcher: View {
    @Binding var current: String
    let variants: [(key: String, name: String)]

    var body: some View {
        let i = variants.firstIndex { $0.key == current } ?? 0
        HStack(spacing: 12) {
            Button { current = variants[(i + variants.count - 1) % variants.count].key } label: { Image(systemName: "chevron.left") }
            Text("\(variants[i].key) · \(variants[i].name)").monospaced()
            Button { current = variants[(i + 1) % variants.count].key } label: { Image(systemName: "chevron.right") }
        }
        .font(.caption.bold())
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(.yellow)
        .background(.black.opacity(0.85), in: .capsule)
        .shadow(radius: 4)
    }
}
