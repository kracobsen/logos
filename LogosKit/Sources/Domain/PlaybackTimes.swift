import Foundation

/// What the player shows for a position: elapsed and left in the current Chapter (for the Chapter-scoped scrubber),
/// and how far through the whole Book it is. All in Book seconds, at 1×.
public struct PlaybackTimes: Sendable, Hashable {
    /// Held to the Book.
    public let position: Double
    public let chapter: Chapter
    public let bookDuration: Double

    public init(position: Double, chapters: ChapterList, bookDuration: Double) {
        self.position = min(max(position, 0), max(bookDuration, 0))
        self.chapter = chapters.chapter(at: self.position)
        self.bookDuration = bookDuration
    }

    public var chapterElapsed: Double { min(max(position - chapter.start, 0), chapter.duration) }
    public var chapterLeft: Double { max(chapter.end - position, 0) }
    /// 0...1 through the Chapter.
    public var chapterFraction: Double { chapter.duration > 0 ? chapterElapsed / chapter.duration : 0 }
    public var bookLeft: Double { max(bookDuration - position, 0) }
    /// 0...1 through the Book.
    public var bookFraction: Double { bookDuration > 0 ? position / bookDuration : 0 }
}
