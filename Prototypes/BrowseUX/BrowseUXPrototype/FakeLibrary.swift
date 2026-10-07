// PROTOTYPE — throwaway. Fake, in-memory Library for the browse/navigation UX prototype.
// Nothing here is the real data model; it only has to look like a ~1000-Book audiobookshelf Library.

import Foundation
import Observation

struct Chapter: Identifiable, Hashable {
    let id: Int
    let title: String
    let start: TimeInterval
    let duration: TimeInterval
}

struct SeriesRef: Hashable {
    let seriesID: Int
    let sequence: Double

    var label: String {
        sequence.rounded() == sequence ? "\(Int(sequence))" : String(format: "%g", sequence)
    }
}

struct Book: Identifiable, Hashable {
    let id: Int
    let title: String
    let author: String
    let narrator: String
    let seriesRef: SeriesRef?
    let duration: TimeInterval
    let chapters: [Chapter]
    let addedAt: Date
    let sizeBytes: Int64
    let hue: Double
    let blurb: String

    /// Title without a leading article, for alphabetical sorting.
    var sortTitle: String {
        for article in ["The ", "A ", "An "] where title.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }
}

struct Series: Identifiable, Hashable {
    let id: Int
    let name: String
    let author: String
    let bookIDs: [Int]  // ordered by sequence
}

struct AuthorName: Hashable {
    let name: String
}

enum DownloadState: Hashable {
    case notDownloaded, queued, downloading(Double), downloaded
}

struct ListenProgress: Hashable {
    var position: TimeInterval
    var finished: Bool
    var lastListened: Date?
}

// MARK: - Store

@MainActor @Observable
final class Library {
    let books: [Book]
    let series: [Series]
    let booksByID: [Int: Book]
    let seriesByID: [Int: Series]

    var downloads: [Int: DownloadState]
    var progress: [Int: ListenProgress]
    var nowPlayingID: Int?
    var isPlaying = false
    var isPlayerPresented = false
    var speed = 1.0

    private var queue: [Int] = []
    private var pumping = false

    init() {
        let data = FakeData.make(count: 1000)
        books = data.books
        series = data.series
        booksByID = Dictionary(uniqueKeysWithValues: data.books.map { ($0.id, $0) })
        seriesByID = Dictionary(uniqueKeysWithValues: data.series.map { ($0.id, $0) })
        downloads = data.downloads
        progress = data.progress
        let pending = data.downloads.filter { $0.value != .downloaded && $0.value != .notDownloaded }
        queue = pending.keys.sorted { (pending[$0] == .queued ? 1 : 0) < (pending[$1] == .queued ? 1 : 0) }  // in-flight first
        nowPlayingID = continueListening.first?.id
        pump()
    }

    // MARK: Queries

    func state(of book: Book) -> DownloadState { downloads[book.id] ?? .notDownloaded }
    func isDownloaded(_ book: Book) -> Bool { state(of: book) == .downloaded }
    func progress(of book: Book) -> ListenProgress { progress[book.id] ?? ListenProgress(position: 0, finished: false) }

    func fraction(of book: Book) -> Double {
        let p = progress(of: book)
        return p.finished ? 1 : p.position / book.duration
    }

    func isInProgress(_ book: Book) -> Bool {
        let p = progress(of: book)
        return !p.finished && p.position > 0
    }

    func series(of book: Book) -> Series? { book.seriesRef.flatMap { seriesByID[$0.seriesID] } }
    func books(in series: Series) -> [Book] { series.bookIDs.compactMap { booksByID[$0] } }

    var nowPlaying: Book? { nowPlayingID.flatMap { booksByID[$0] } }

    /// In-progress downloaded Books, most recently listened first.
    var continueListening: [Book] {
        books.filter { isInProgress($0) && isDownloaded($0) }
            .sorted { (progress(of: $0).lastListened ?? .distantPast) > (progress(of: $1).lastListened ?? .distantPast) }
    }

    var downloadedBooks: [Book] { books.filter(isDownloaded) }
    var activeDownloads: [Book] { queue.compactMap { booksByID[$0] } }
    var downloadedBytes: Int64 { downloadedBooks.reduce(0) { $0 + $1.sizeBytes } }

    /// The first Book in a Series that isn't finished.
    func nextUp(in series: Series) -> Book? { books(in: series).first { !progress(of: $0).finished } }

    func currentChapter(of book: Book) -> Chapter {
        let position = progress(of: book).position
        return book.chapters.last { $0.start <= position } ?? book.chapters[0]
    }

    // MARK: Actions (all stubs)

    func download(_ book: Book) {
        guard state(of: book) == .notDownloaded else { return }
        downloads[book.id] = .queued
        queue.append(book.id)
        pump()
    }

    func removeDownload(_ book: Book) {
        downloads[book.id] = .notDownloaded
        queue.removeAll { $0 == book.id }
        if nowPlayingID == book.id { isPlaying = false }
    }

    func play(_ book: Book, from chapter: Chapter? = nil) {
        guard isDownloaded(book) else { return }
        nowPlayingID = book.id
        var p = progress(of: book)
        if let chapter { p.position = chapter.start }
        p.lastListened = .now
        progress[book.id] = p
        isPlaying = true
        isPlayerPresented = true
    }

    func skip(_ seconds: TimeInterval) {
        guard let book = nowPlaying else { return }
        var p = progress(of: book)
        p.position = min(max(0, p.position + seconds), book.duration)
        progress[book.id] = p
    }

    func seek(to position: TimeInterval) {
        guard let book = nowPlaying else { return }
        progress[book.id]?.position = position
    }

    /// One Book at a time, first in first out — mirrors the download manager decision.
    private func pump() {
        guard !pumping, !queue.isEmpty else { return }
        pumping = true
        Task { @MainActor in
            while let id = queue.first {
                var step = 0.0
                if case .downloading(let f) = downloads[id] { step = f }
                while step < 1, queue.first == id {
                    try? await Task.sleep(for: .milliseconds(120))
                    step = min(1, step + 0.04)
                    downloads[id] = .downloading(step)
                }
                if queue.first == id {
                    downloads[id] = .downloaded
                    queue.removeFirst()
                }
            }
            pumping = false
        }
    }
}

// MARK: - Fake data

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum FakeData {
    static let firstNames = ["Ada", "Ben", "Clara", "Dmitri", "Elif", "Farah", "Gustav", "Hanne", "Ivo", "Jun", "Kari", "Lena", "Marek", "Nora", "Omar", "Petra", "Quentin", "Rhea", "Sven", "Tove", "Ulla", "Viktor", "Wen", "Ximena", "Yusuf", "Zoe", "Arne", "Bodil", "Cyrus", "Dagny", "Emeka", "Freya", "Ingrid", "Jonas", "Leif", "Maren", "Nils", "Sigrid", "Tarjei", "Vera"]
    static let lastNames = ["Abbott", "Berg", "Castellanos", "Dahl", "Eriksen", "Fairweather", "Grieg", "Halvorsen", "Ishikawa", "Jansen", "Kowalski", "Lindqvist", "Moreau", "Nakamura", "Okafor", "Pettersen", "Quinn", "Rasmussen", "Strand", "Thorsen", "Ueda", "Valdez", "Whitlock", "Yilmaz", "Zielinski", "Aune", "Bakke", "Holm", "Lund", "Moe", "Nygaard", "Solberg", "Vik"]
    static let adjectives = ["Silent", "Broken", "Golden", "Hollow", "Last", "Burning", "Northern", "Forgotten", "Iron", "Glass", "Distant", "Hidden", "Crimson", "Winter", "Quiet", "Wandering", "Seventh", "Drowned", "Pale", "Endless", "Bright", "Salt", "Midnight", "Shattered"]
    static let nouns = ["Harbor", "Crown", "Library", "Tide", "Orchard", "Engine", "Lantern", "Garden", "Fjord", "Empire", "Archive", "Compass", "River", "Tower", "Signal", "Kingdom", "Mirror", "Voyage", "Season", "Machine", "Witness", "Cartographer", "Bridge", "Storm", "Clockmaker", "Atlas", "Shore", "Choir"]
    static let places = ["Ashford", "the North", "Tromsø", "Kepler Station", "the Deep", "Old Bergen", "the Valley", "Mars", "the Long Coast", "Halden", "Nowhere", "Saltmarsh"]
    static let seriesWords = ["Chronicles", "Saga", "Cycle", "Trilogy", "Sequence", "Quartet", "Archives", "Mysteries", "Files", "Legacy", "Expanse", "Duology"]

    static func make(count: Int) -> (books: [Book], series: [Series], downloads: [Int: DownloadState], progress: [Int: ListenProgress]) {
        var rng = SeededRNG(state: 42)
        let authors = (0..<140).map { _ in "\(firstNames.randomElement(using: &rng)!) \(lastNames.randomElement(using: &rng)!)" }
        let now = Date.now
        var books: [Book] = []
        var series: [Series] = []

        func title() -> String {
            let a = adjectives.randomElement(using: &rng)!
            let n = nouns.randomElement(using: &rng)!
            let n2 = nouns.randomElement(using: &rng)!
            let p = places.randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: return "The \(a) \(n)"
            case 1: return "\(n) of \(p)"
            case 2: return "A \(n) for the \(a) \(n2)"
            case 3: return "\(a) \(n)"
            case 4: return "The \(n) and the \(n2)"
            default: return "\(a) \(n): A Novel of \(p)"
            }
        }

        func book(author: String, seriesRef: SeriesRef?) -> Book {
            let id = books.count
            let hours = Double.random(in: 2.5...38, using: &rng)
            let duration = (hours * 3600).rounded()
            let t = title()
            var chapters: [Chapter] = []
            if Int.random(in: 0..<20, using: &rng) == 0 {
                chapters = [Chapter(id: 0, title: t, start: 0, duration: duration)]  // no Chapters on the Server
            } else {
                let n = min(80, max(3, Int(duration / Double.random(in: 1200...3600, using: &rng))))
                let named = Bool.random(using: &rng)
                let each = duration / Double(n)
                chapters = (0..<n).map { i in
                    let title: String
                    if named && i == 0 { title = "Prologue" }
                    else if named && i == n - 1 { title = "Epilogue" }
                    else { title = "Chapter \(named ? i : i + 1)" }
                    return Chapter(id: i, title: title, start: Double(i) * each, duration: each)
                }
            }
            return Book(
                id: id, title: t, author: author,
                narrator: "\(firstNames.randomElement(using: &rng)!) \(lastNames.randomElement(using: &rng)!)",
                seriesRef: seriesRef, duration: duration, chapters: chapters,
                addedAt: now.addingTimeInterval(-Double.random(in: 0...(3 * 365 * 86400), using: &rng)),
                sizeBytes: Int64(duration * Double.random(in: 7000...12000, using: &rng)),
                hue: Double.random(in: 0...1, using: &rng),
                blurb: "A sweeping story about \(nouns.randomElement(using: &rng)!.lowercased())s, \(adjectives.randomElement(using: &rng)!.lowercased()) promises and the long road to \(places.randomElement(using: &rng)!). Placeholder copy — the real description comes from the Server."
            )
        }

        while books.count < count {
            let author = authors.randomElement(using: &rng)!
            if Double.random(in: 0..<1, using: &rng) < 0.4 {
                let sid = series.count
                let name = "The \(adjectives.randomElement(using: &rng)!) \(nouns.randomElement(using: &rng)!) \(seriesWords.randomElement(using: &rng)!)"
                var ids: [Int] = []
                var seq = 1.0
                for i in 0..<Int.random(in: 2...12, using: &rng) where books.count < count {
                    let novella = i > 0 && Int.random(in: 0..<8, using: &rng) == 0
                    let b = book(author: author, seriesRef: SeriesRef(seriesID: sid, sequence: novella ? seq - 0.5 : seq))
                    if !novella { seq += 1 }
                    books.append(b)
                    ids.append(b.id)
                }
                series.append(Series(id: sid, name: name, author: author, bookIDs: ids))
            } else {
                books.append(book(author: author, seriesRef: nil))
            }
        }

        var downloads: [Int: DownloadState] = [:]
        var progress: [Int: ListenProgress] = [:]
        for b in books.shuffled(using: &rng).prefix(220) {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...5:
                progress[b.id] = ListenProgress(position: b.duration, finished: true, lastListened: now.addingTimeInterval(-Double.random(in: 86400...(700 * 86400), using: &rng)))
            default:
                progress[b.id] = ListenProgress(position: b.duration * Double.random(in: 0.03...0.95, using: &rng), finished: false, lastListened: now.addingTimeInterval(-Double.random(in: 600...(60 * 86400), using: &rng)))
                downloads[b.id] = .downloaded
            }
        }
        for b in books.shuffled(using: &rng).prefix(30) where downloads[b.id] == nil {
            downloads[b.id] = .downloaded
        }
        let pending = books.shuffled(using: &rng).filter { downloads[$0.id] == nil }.prefix(3)
        for (i, b) in pending.enumerated() {
            downloads[b.id] = i == 0 ? .downloading(0.35) : .queued
        }
        return (books, series, downloads, progress)
    }
}
