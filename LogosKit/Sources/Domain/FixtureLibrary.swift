import Foundation

/// A made-up Library of any size, the same every time: what the performance tests measure the budgets on (the
/// 3000-Book budgets in `docs/performance-budgets.md`), seeded by UI-test launches of the app.
///
/// Titles spread over every index letter (a few start with a digit or an article), authors write several Books, about
/// a third of the Books are in Series (sequences counted from 1, now and then a "1.5"), most have a cover, and some
/// have progress: in progress or Finished. A few Books are meant to come downloaded (``downloadedBookIDs``): those are
/// short, with ``downloadedTrackCount`` files of ``downloadedTrackDuration`` seconds each, so their audio can be made
/// on the device, and they're the most recently listened to (the first is the last-played Book).
///
/// Like `TestClock` and `FakeServer`, it lives in the sources so test targets and the app's UI-test launch can share it.
public struct FixtureLibrary: Sendable, Hashable {
    /// How many files each downloaded Book has.
    public static let downloadedTrackCount = 2
    /// The length of each downloaded Book's files, in seconds.
    public static let downloadedTrackDuration: Double = 120

    /// Full data for every Book, in id order.
    public let books: [BookData]
    /// The listener's progress, as the Server would give it.
    public let progress: [FetchedProgress]
    /// The Books that come downloaded, most recently listened to first.
    public let downloadedBookIDs: [String]

    /// The Library list (sync stage 1 data).
    public var listedBooks: [ListedBook] { books.map(\.book) }

    public init(bookCount: Int, downloadedCount: Int = 3) {
        var generator = Generator()
        let authorCount = max(1, bookCount / 4)
        let downloaded = Set(
            (0..<min(downloadedCount, bookCount)).map { $0 * max(1, bookCount / max(1, downloadedCount)) })

        var books: [BookData] = []
        books.reserveCapacity(bookCount)
        var series: (id: String, name: String, author: Int, next: Int, left: Int)?
        var seriesCount = 0
        for index in 0..<bookCount {
            if series == nil || series?.left == 0 {
                series = nil
                if generator.chance(0.12) {
                    seriesCount += 1
                    series = (
                        "fixture-series-\(seriesCount)", "\(generator.titleWord()) \(generator.pick(Self.seriesWords))",
                        generator.int(below: authorCount), 1, 2 + generator.int(below: 7)
                    )
                }
            }
            let author = series?.author ?? generator.int(below: authorCount)
            var membership: SeriesMembership?
            if let current = series {
                let sequence =
                    current.next > 1 && generator.chance(0.05) ? "\(current.next - 1).5" : "\(current.next)"
                membership = SeriesMembership(seriesID: current.id, name: current.name, sequence: sequence)
                series?.next += 1
                series?.left -= 1
            }
            books.append(
                Self.book(
                    index: index, author: author, series: membership, isDownloaded: downloaded.contains(index),
                    generator: &generator))
        }
        self.books = books

        let downloadedIDs = books.indices.filter { downloaded.contains($0) }.map { books[$0].book.id }
        downloadedBookIDs = downloadedIDs
        let newest: Int64 = 1_790_000_000_000
        var progress: [FetchedProgress] = downloadedIDs.enumerated().map { order, id in
            FetchedProgress(bookID: id, position: 30, isFinished: false, lastUpdate: newest - Int64(order) * 60_000)
        }
        for (index, data) in books.enumerated() where !downloaded.contains(index) {
            let roll = generator.int(below: 100)
            guard roll < 18 else { continue }
            let lastUpdate = newest - 3_600_000 - Int64(generator.int(below: 400 * 24)) * 3_600_000
            if roll < 6 {
                progress.append(
                    FetchedProgress(
                        bookID: data.book.id, position: data.book.duration, isFinished: true, lastUpdate: lastUpdate))
            } else {
                let position = (data.book.duration * Double(1 + generator.int(below: 98)) / 100).rounded()
                progress.append(
                    FetchedProgress(bookID: data.book.id, position: position, isFinished: false, lastUpdate: lastUpdate)
                )
            }
        }
        self.progress = progress
    }

    private static func book(
        index: Int, author: Int, series: SeriesMembership?, isDownloaded: Bool, generator: inout Generator
    ) -> BookData {
        let id = String(format: "fixture-book-%05d", index)
        let title = generator.title()
        let first = firstNames[author % firstNames.count]
        let last = lastNames[(author / firstNames.count) % lastNames.count]
        let suffix = author / (firstNames.count * lastNames.count)
        let lastName = suffix == 0 ? last : "\(last) \(suffix + 1)"
        let duration: Double
        let tracks: [AudioTrack]
        let chapters: [Chapter]
        if isDownloaded {
            let length = downloadedTrackDuration
            duration = length * Double(downloadedTrackCount)
            tracks = (0..<downloadedTrackCount).map { file in
                AudioTrack(
                    index: file + 1, ino: "\(id)-ino-\(file + 1)", relPath: String(format: "%02d.m4a", file + 1),
                    size: 0, duration: length, startOffset: Double(file) * length, mimeType: "audio/mp4")
            }
            chapters = stride(from: 0.0, to: duration, by: 60).enumerated().map { number, start in
                Chapter(id: number, start: start, end: start + 60, title: "Chapter \(number + 1)")
            }
        } else {
            duration = Double(2 * 3600 + generator.int(below: 28 * 3600))
            tracks = [
                AudioTrack(
                    index: 1, ino: "\(id)-ino-1", relPath: "\(id).m4b", size: Int64(duration * 16_000),
                    duration: duration, startOffset: 0, mimeType: "audio/mp4")
            ]
            let chapterLength = Double(900 + generator.int(below: 2700))
            chapters = stride(from: 0.0, to: duration, by: chapterLength).enumerated().map { number, start in
                Chapter(
                    id: number, start: start, end: min(start + chapterLength, duration), title: "Chapter \(number + 1)")
            }
        }
        let listed = ListedBook(
            id: id,
            mediaID: String(format: "fixture-media-%05d", index),
            title: title,
            subtitle: generator.chance(0.2) ? "A \(generator.titleWord()) Story" : nil,
            authorName: "\(first) \(lastName)",
            authorNameLF: "\(lastName), \(first)",
            narratorName: "\(generator.pick(firstNames)) \(generator.pick(lastNames))",
            seriesName: series.map { series in series.sequence.map { "\(series.name) #\($0)" } ?? series.name } ?? "",
            description: generator.chance(0.6) ? "<p>\(title): a made-up Book for measuring Logos.</p>" : nil,
            publishedYear: "\(1950 + generator.int(below: 76))",
            genres: [generator.pick(genres)],
            addedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(generator.int(below: 170_000_000))),
            updatedAt: 1_700_000_000_000 + Int64(index),
            duration: duration,
            size: tracks.reduce(0) { $0 + $1.size },
            hasCover: isDownloaded || generator.chance(0.9))
        return BookData(book: listed, chapters: chapters, tracks: tracks, series: series.map { [$0] } ?? [])
    }

    private static let seriesWords = ["Saga", "Chronicles", "Cycle", "Trilogy", "Quartet", "Mysteries", "Tales"]
    private static let genres = ["Fiction", "Fantasy", "Mystery", "History", "Science", "Biography", "Thriller"]
    private static let firstNames = [
        "Ada", "Ben", "Cora", "Dan", "Edith", "Finn", "Greta", "Hugo", "Ines", "Jon", "Kari", "Leo", "Maja", "Nils",
        "Olga", "Per", "Rita", "Sven", "Tove", "Uma", "Vera", "Will", "Yara", "Zeno",
    ]
    private static let lastNames = [
        "Andersen", "Berg", "Carlsen", "Dahl", "Eriksen", "Foss", "Grieg", "Hansen", "Iversen", "Johansen", "Kvist",
        "Lund", "Moe", "Nilsen", "Olsen", "Pettersen", "Quist", "Rud", "Strand", "Toft", "Ullmann", "Vik", "Wold",
        "Yttre", "Zahl",
    ]
    static let words = [
        "Amber", "Arrow", "Bright", "Brook", "Crown", "Cinder", "Dawn", "Drift", "Echo", "Ember", "Frost", "Falcon",
        "Garden", "Glass", "Harbor", "Hollow", "Iron", "Island", "Jade", "Journey", "Kestrel", "King", "Lantern",
        "Light", "Meadow", "Mirror", "North", "Night", "Ocean", "Orchard", "Pale", "Pilgrim", "Quiet", "Quarry",
        "River",
        "Raven", "Silver", "Stone", "Thunder", "Tide", "Under", "Umber", "Valley", "Velvet", "Winter", "Willow",
        "Xenon", "Xylo", "Yellow", "Yarrow", "Zenith", "Zephyr",
    ]
    static let tailWords = [
        "of the North", "and Ash", "Rising", "at Dusk", "in Winter", "Road", "House", "Song", "Keeper", "Lost",
    ]

    /// SplitMix64: small, fast and the same on every platform.
    struct Generator: Sendable {
        private var state: UInt64 = 0x4C6F_676F_7346_6978

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ probability: Double) -> Bool { Double(next() % 10_000) < probability * 10_000 }
        mutating func pick<T>(_ items: [T]) -> T { items[int(below: items.count)] }
        mutating func titleWord() -> String { pick(FixtureLibrary.words) }

        mutating func title() -> String {
            let roll = int(below: 100)
            if roll < 2 { return "\(1 + int(below: 2100)) \(titleWord()) Nights" }
            let core = int(below: 2) == 0 ? titleWord() : "\(titleWord()) \(titleWord())"
            let tail = chance(0.4) ? " \(pick(FixtureLibrary.tailWords))" : ""
            return (roll < 14 ? "The " : "") + core + tail
        }
    }
}
