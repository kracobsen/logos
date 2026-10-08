import Foundation

/// One Book as a Library row: just what the list shows, sorts, filters and searches on.
///
/// The Library tab holds every row in memory, loaded by one lightweight query, so keep this small. Full Book data
/// (description, Chapters, tracks, Series) lives elsewhere.
public struct LibraryRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let authorName: String
    public let narratorName: String
    /// The Server's display string for the Book's Series, e.g. `"Saga #1.5, Other #2"`. Empty when none.
    public let seriesName: String
    public let addedAt: Date
    /// In seconds.
    public let duration: Double
    /// "Last, First" (`authorNameLF`): what Author order sorts by.
    public let authorNameLF: String

    /// The title without a leading The, A or An: what Title order sorts by.
    public let sortTitle: String

    public init(
        id: String,
        title: String,
        authorName: String,
        authorNameLF: String,
        narratorName: String,
        seriesName: String,
        addedAt: Date,
        duration: Double
    ) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.narratorName = narratorName
        self.seriesName = seriesName
        self.addedAt = addedAt
        self.duration = duration
        self.authorNameLF = authorNameLF
        self.sortTitle = TitleSort.sortTitle(title)
    }

    /// The letter-index entry for this row in Title order: the first letter of ``sortTitle`` folded to A–Z, or `#`.
    public var indexLetter: String { TitleSort.indexLetter(sortTitle) }
}

/// Title order: A–Z ignoring a leading The, A or An, and ignoring case and diacritics, with numbers by value.
public enum TitleSort {
    /// The leading words Title order skips. Only a whole word followed by more of the title counts.
    static let articles = ["the", "a", "an"]

    /// The letter-index entry for titles that don't start with a letter A–Z.
    public static let otherLetter = "#"

    /// `title` without leading whitespace and without a leading article.
    public static func sortTitle(_ title: String) -> String {
        let trimmed = title.drop(while: \.isWhitespace)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return String(trimmed) }
        let firstWord = trimmed[..<space].lowercased()
        guard articles.contains(firstWord) else { return String(trimmed) }
        let rest = trimmed[space...].drop(while: \.isWhitespace)
        return rest.isEmpty ? String(trimmed) : String(rest)
    }

    /// Whether `a` comes before `b` in Title order. Both are sort titles (see ``sortTitle(_:)``).
    public static func areInIncreasingOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric])
            == .orderedAscending
    }

    /// The letter-index entry for a sort title.
    public static func indexLetter(_ sortTitle: String) -> String {
        guard let first = sortTitle.first else { return otherLetter }
        let folded = String(first).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
        )
        .uppercased()
        guard folded.count == 1, let scalar = folded.unicodeScalars.first, ("A"..."Z").contains(scalar) else {
            return otherLetter
        }
        return folded
    }
}

/// A run of rows under one letter of the index.
public struct TitleSection: Sendable, Hashable, Identifiable {
    public let letter: String
    public let rows: [LibraryRow]

    public var id: String { letter }

    public init(letter: String, rows: [LibraryRow]) {
        self.letter = letter
        self.rows = rows
    }
}

extension Sequence<LibraryRow> {
    /// The rows in Title order; equal titles are ordered by id so the order is stable.
    public func sortedByTitle() -> [LibraryRow] {
        sorted { a, b in
            if TitleSort.areInIncreasingOrder(a.sortTitle, b.sortTitle) { return true }
            if TitleSort.areInIncreasingOrder(b.sortTitle, a.sortTitle) { return false }
            return a.id < b.id
        }
    }

    /// The rows in Title order, grouped by index letter: `#` first (everything not starting with A–Z), then A–Z.
    public func sectionedByTitle() -> [TitleSection] {
        var byLetter: [String: [LibraryRow]] = [:]
        for row in sortedByTitle() {
            byLetter[row.indexLetter, default: []].append(row)
        }
        return byLetter.keys.sorted { a, b in
            if a == TitleSort.otherLetter { return b != TitleSort.otherLetter }
            if b == TitleSort.otherLetter { return false }
            return a < b
        }
        .map { TitleSection(letter: $0, rows: byLetter[$0] ?? []) }
    }
}
