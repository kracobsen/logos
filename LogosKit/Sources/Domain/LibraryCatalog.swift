import Foundation

/// The Library tab's sort orders.
public enum LibrarySort: String, CaseIterable, Sendable {
    case title, author, recentlyAdded, recentlyListened
}

/// The Library tab's filters, by the listener's progress.
public enum LibraryFilter: String, CaseIterable, Sendable {
    case all, notStarted, inProgress, finished

    /// Whether a Book with this progress (`nil`: none) passes the filter.
    public func includes(_ progress: BookProgress?) -> Bool {
        switch self {
        case .all: true
        case .notStarted: progress.map { !$0.isFinished && $0.position <= 0 } ?? true
        case .inProgress: progress?.isInProgress ?? false
        case .finished: progress?.isFinished ?? false
        }
    }
}

/// What the Library tab shows: a sort, a filter and the search text.
public struct LibraryQuery: Sendable, Hashable {
    public var sort: LibrarySort
    public var filter: LibraryFilter
    public var search: String

    public init(sort: LibrarySort = .title, filter: LibraryFilter = .all, search: String = "") {
        self.sort = sort
        self.filter = filter
        self.search = search
    }
}

/// A Series as the Library search knows it.
public struct LibrarySeries: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// The Series' Books in reading order.
    public let bookIDs: [String]

    public init(id: String, name: String, bookIDs: [String]) {
        self.id = id
        self.name = name
        self.bookIDs = bookIDs
    }
}

/// The Library tab's list for one query.
public struct LibraryResults: Sendable, Hashable {
    /// Matching Series, shown above the Books. Empty unless searching.
    public let series: [LibrarySeries]
    /// Rows in order. Sectioned by letter when ``showsIndex``, else one section with an empty letter.
    public let sections: [TitleSection]
    /// Whether the letter index shows: only for Title and Author order, and never while searching.
    public let showsIndex: Bool

    public init(series: [LibrarySeries], sections: [TitleSection], showsIndex: Bool) {
        self.series = series
        self.sections = sections
        self.showsIndex = showsIndex
    }

    public var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }
}

/// Search folding: substring matching that ignores case, diacritics and character width. No FTS.
public enum SearchFolding {
    /// `text` folded for matching.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The search text as a folded needle, or `nil` when it's blank (not searching).
    public static func needle(_ search: String) -> String? {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : fold(trimmed)
    }
}

/// Every Library row (and Series), ready to be sorted, filtered and searched in memory.
///
/// Building one sorts the rows into Title order and folds every row's search text once. A sort change is then one
/// ``ordered(by:progress:)``, and a search keystroke or filter change is one ``LibraryOrder/results(filter:search:progress:)``:
/// a pass of substring checks over the already-ordered rows.
public struct LibraryCatalog: Sendable {
    struct Entry: Sendable {
        let row: LibraryRow
        /// Position in Title order: the tie-break for every other order.
        let titleRank: Int
        /// Title, author, narrator and Series name, folded, one per line.
        let haystack: String
    }

    struct SeriesEntry: Sendable {
        let series: LibrarySeries
        let foldedName: String
    }

    /// In Title order.
    let entries: [Entry]
    /// By name, A–Z.
    let series: [SeriesEntry]

    public init(rows: [LibraryRow], series: [LibrarySeries]) {
        entries = rows.sortedByTitle().enumerated().map { rank, row in
            Entry(
                row: row,
                titleRank: rank,
                haystack: SearchFolding.fold(
                    [row.title, row.authorName, row.narratorName, row.seriesName].joined(separator: "\n"))
            )
        }
        self.series = series.sorted { TitleSort.areInIncreasingOrder($0.name, $1.name) }
            .map { SeriesEntry(series: $0, foldedName: SearchFolding.fold($0.name)) }
    }

    public var rowCount: Int { entries.count }

    /// The rows in `sort` order. Only Recently listened reads `progress`.
    public func ordered(by sort: LibrarySort, progress: [String: BookProgress]) -> LibraryOrder {
        let ordered: [Entry]
        switch sort {
        case .title:
            ordered = entries
        case .author:
            ordered = entries.sorted { a, b in
                if TitleSort.areInIncreasingOrder(a.row.authorNameLF, b.row.authorNameLF) { return true }
                if TitleSort.areInIncreasingOrder(b.row.authorNameLF, a.row.authorNameLF) { return false }
                return a.titleRank < b.titleRank
            }
        case .recentlyAdded:
            ordered = entries.sorted { a, b in
                a.row.addedAt != b.row.addedAt ? a.row.addedAt > b.row.addedAt : a.titleRank < b.titleRank
            }
        case .recentlyListened:
            let listened = entries.compactMap { entry in progress[entry.row.id].map { (entry, $0.lastChanged) } }
                .sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.titleRank < b.0.titleRank }
                .map(\.0)
            ordered = listened + entries.filter { progress[$0.row.id] == nil }
        }
        return LibraryOrder(sort: sort, entries: ordered, series: series)
    }

    /// The list for `query`. To follow keystrokes, keep ``ordered(by:progress:)`` and call its results instead.
    public func results(_ query: LibraryQuery, progress: [String: BookProgress]) -> LibraryResults {
        ordered(by: query.sort, progress: progress).results(
            filter: query.filter, search: query.search, progress: progress)
    }
}

/// The Library's rows in one sort order, ready to filter and search.
public struct LibraryOrder: Sendable {
    public let sort: LibrarySort
    let entries: [LibraryCatalog.Entry]
    let series: [LibraryCatalog.SeriesEntry]

    public func results(filter: LibraryFilter, search: String, progress: [String: BookProgress]) -> LibraryResults {
        let needle = SearchFolding.needle(search)
        var rows: [LibraryRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            if filter != .all, !filter.includes(progress[entry.row.id]) { continue }
            if let needle, !entry.haystack.contains(needle) { continue }
            rows.append(entry.row)
        }
        if let needle {
            let series = series.lazy
                .filter { $0.foldedName.contains(needle) }
                .filter { entry in filter == .all || entry.series.bookIDs.contains { filter.includes(progress[$0]) } }
                .map(\.series)
            return LibraryResults(series: Array(series), sections: Self.oneSection(rows), showsIndex: false)
        }
        guard sort == .title || sort == .author else {
            return LibraryResults(series: [], sections: Self.oneSection(rows), showsIndex: false)
        }
        let letter: (LibraryRow) -> String =
            sort == .author ? { TitleSort.indexLetter($0.authorNameLF) } : { $0.indexLetter }
        return LibraryResults(series: [], sections: rows.sectionedByLetter(letter), showsIndex: true)
    }

    static func oneSection(_ rows: [LibraryRow]) -> [TitleSection] {
        rows.isEmpty ? [] : [TitleSection(letter: "", rows: rows)]
    }
}

extension Array<LibraryRow> {
    /// Ordered rows grouped by letter, keeping their order within each letter: `#` first, then A–Z.
    func sectionedByLetter(_ letter: (LibraryRow) -> String) -> [TitleSection] {
        var byLetter: [String: [LibraryRow]] = [:]
        for row in self {
            byLetter[letter(row), default: []].append(row)
        }
        return byLetter.keys.sorted { a, b in
            if a == TitleSort.otherLetter { return b != TitleSort.otherLetter }
            if b == TitleSort.otherLetter { return false }
            return a < b
        }
        .map { TitleSection(letter: $0, rows: byLetter[$0] ?? []) }
    }
}
