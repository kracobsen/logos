import Foundation

/// A named section of a Book, as the Server reports it. Times are Book seconds.
public struct Chapter: Sendable, Hashable, Identifiable {
    /// The Server's Chapter id (its index within the Book).
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public init(id: Int, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }

    /// In seconds.
    public var duration: Double { end - start }
}

/// A Book's Chapters in Book order, never empty: a Book the Server reports no Chapters for is one Chapter spanning
/// the whole Book, named after it.
///
/// Answers "which Chapter is this position in?" for the detail screen, the player and the Sleep Timer.
public struct ChapterList: Sendable, Hashable {
    /// Sorted by start; at least one.
    public let chapters: [Chapter]

    public init(_ chapters: [Chapter], bookDuration: Double, bookTitle: String) {
        if chapters.isEmpty {
            self.chapters = [Chapter(id: 0, start: 0, end: bookDuration, title: bookTitle)]
        } else {
            self.chapters = chapters.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        }
    }

    public var count: Int { chapters.count }

    /// The index of the Chapter that holds `position`: the last Chapter starting at or before it. A boundary belongs
    /// to the Chapter it starts, a gap to the Chapter before it, anything before the first Chapter to the first, and
    /// the end of the Book (or beyond) to the last.
    public func index(at position: Double) -> Int {
        // Binary search for the first Chapter starting after `position`.
        var low = 0
        var high = chapters.count
        while low < high {
            let middle = (low + high) / 2
            if chapters[middle].start <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low - 1, 0)
    }

    /// The Chapter that holds `position` (see ``index(at:)``).
    public func chapter(at position: Double) -> Chapter {
        chapters[index(at: position)]
    }
}
