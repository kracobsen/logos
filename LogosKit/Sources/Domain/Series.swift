import Foundation

/// One Series in the Series tab. Series are derived from the Books' `series[]`; there are no `/series` calls.
public struct SeriesSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// How many Books in the Library belong to it.
    public let bookCount: Int

    public init(id: String, name: String, bookCount: Int) {
        self.id = id
        self.name = name
        self.bookCount = bookCount
    }
}

extension Sequence<SeriesSummary> {
    /// A–Z by name, the way Title order sorts titles (a leading The/A/An is ignored); equal names by id.
    public func sortedByName() -> [SeriesSummary] {
        map { (sortName: TitleSort.sortTitle($0.name), series: $0) }
            .sorted { a, b in
                if TitleSort.areInIncreasingOrder(a.sortName, b.sortName) { return true }
                if TitleSort.areInIncreasingOrder(b.sortName, a.sortName) { return false }
                return a.series.id < b.series.id
            }
            .map(\.series)
    }
}

/// One Book on a Series page: its place in the Series, and what the Continue button needs to know about it.
public struct SeriesBook: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// Its sequence in this Series as the Server gives it (`"1"`, `"1.5"`, `"1a"`), or `nil`. Display it verbatim.
    public let sequence: String?
    public let publishedYear: String?
    /// In Book seconds; 0 when not started.
    public let position: TimeInterval
    public let isFinished: Bool
    public let isDownloaded: Bool

    public init(
        id: String,
        title: String,
        sequence: String?,
        publishedYear: String?,
        position: TimeInterval,
        isFinished: Bool,
        isDownloaded: Bool
    ) {
        self.id = id
        self.title = title
        self.sequence = sequence
        self.publishedYear = publishedYear
        self.position = position
        self.isFinished = isFinished
        self.isDownloaded = isDownloaded
    }

    /// Started at some point: it has a position, or it's Finished.
    public var isStarted: Bool { isFinished || position > 0 }
}

/// One Series with its Books, for the Series page.
public struct SeriesPage: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// In reading order (see ``SeriesOrder``).
    public let books: [SeriesBook]

    public init(id: String, name: String, books: [SeriesBook]) {
        self.id = id
        self.name = name
        self.books = books.inReadingOrder()
    }

    /// The Continue button's target, or `nil` for no button.
    public var continueTarget: SeriesContinue? { SeriesContinue.target(in: books) }
}

/// A Series' reading order:the sequence read as a decimal; Books with an empty or non-numeric sequence last, by
/// published year then title.
public enum SeriesOrder {
    /// The sequence as a decimal number, or `nil` if it isn't one: optional surrounding spaces, digits, optionally
    /// a `.` and more digits. Nothing else counts (no signs, exponents, `nan`, commas).
    public static func number(_ sequence: String?) -> Decimal? {
        guard let trimmed = sequence?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else {
            return nil
        }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Whether `a` comes before `b` in reading order.
    public static func areInIncreasingOrder(_ a: SeriesBook, _ b: SeriesBook) -> Bool {
        switch (number(a.sequence), number(b.sequence)) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        switch (year(a.publishedYear), year(b.publishedYear)) {
        case (let x?, let y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        let titleA = TitleSort.sortTitle(a.title)
        let titleB = TitleSort.sortTitle(b.title)
        if TitleSort.areInIncreasingOrder(titleA, titleB) { return true }
        if TitleSort.areInIncreasingOrder(titleB, titleA) { return false }
        return a.id < b.id
    }

    /// The Server's `publishedYear` (a string, e.g. `"2001"`) as a number; unknown years sort after known ones.
    static func year(_ publishedYear: String?) -> Int? {
        publishedYear.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}

extension Sequence<SeriesBook> {
    /// The Books in the Series' reading order (see ``SeriesOrder``).
    public func inReadingOrder() -> [SeriesBook] {
        sorted(by: SeriesOrder.areInIncreasingOrder)
    }
}

/// The Series page's one button: the Book to continue with, and whether that means playing or downloading it.
public struct SeriesContinue: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// The Book is downloaded: "Continue with Book N".
        case play
        /// It isn't: "Download Book N to continue".
        case download
    }

    public let book: SeriesBook
    public let action: Action

    /// The target in `books`: the first unfinished Book at or after the furthest-along started one, in reading
    /// order. The furthest-along started Book is itself the target while it's unfinished; with nothing started it's
    /// the first unfinished Book. `nil` when everything from there on is Finished (no button).
    public static func target(in books: [SeriesBook]) -> SeriesContinue? {
        let ordered = books.inReadingOrder()
        let from = ordered.lastIndex(where: \.isStarted) ?? ordered.startIndex
        guard let book = ordered[from...].first(where: { !$0.isFinished }) else { return nil }
        return SeriesContinue(book: book, action: book.isDownloaded ? .play : .download)
    }

    /// "Continue with Book 2" / "Download Book 2 to continue". N is the sequence as given, or the title when the
    /// Book has none.
    public var label: String {
        let name: String
        if let sequence = book.sequence, !sequence.trimmingCharacters(in: .whitespaces).isEmpty {
            name = "Book \(sequence)"
        } else {
            name = book.title
        }
        switch action {
        case .play: return "Continue with \(name)"
        case .download: return "Download \(name) to continue"
        }
    }
}
