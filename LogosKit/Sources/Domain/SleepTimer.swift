import Foundation

/// A request to stop playback at the end of the Xth Chapter from now, counting the Chapter playing as the first,
/// resolved to an absolute Book-time stop point. Chapter-based only; held in memory by the player.
public struct SleepTimer: Sendable, Hashable {
    /// The index of the last Chapter that plays: the stop is at its end.
    public let chapterIndex: Int
    /// Where playback stops, in Book seconds: the end of that Chapter (held to the Book).
    public let stopAt: Double
    /// Where the position is saved after the stop: the start of the next Chapter (or the stop itself, if there's no
    /// next Chapter).
    public let resumeAt: Double
    /// Whether the stop is the end of the Book, which the end-of-Book handling covers instead of a boundary.
    public let endsBook: Bool

    /// Stops at the end of the `count`th Chapter from `position` (1 = "End of this Chapter"). `nil` if the Book has
    /// fewer Chapters left than that, or `count` is less than 1.
    public init?(chapters count: Int, from position: Double, in chapters: ChapterList, bookDuration: Double) {
        guard count >= 1 else { return nil }
        self.init(chapterIndex: chapters.index(at: position) + count - 1, in: chapters, bookDuration: bookDuration)
    }

    private init?(chapterIndex: Int, in chapters: ChapterList, bookDuration: Double) {
        guard chapters.chapters.indices.contains(chapterIndex) else { return nil }
        self.chapterIndex = chapterIndex
        stopAt = min(chapters.chapters[chapterIndex].end, bookDuration)
        let next = chapterIndex + 1
        resumeAt = chapters.chapters.indices.contains(next) ? max(chapters.chapters[next].start, stopAt) : stopAt
        endsBook = stopAt >= bookDuration
    }

    /// The Chapter's number as the listener counts them, from 1 ("Stops at end of Chapter 7").
    public var chapterNumber: Int { chapterIndex + 1 }

    /// The projected wall-clock seconds from `position` to the stop at `rate` ("~42 min").
    public func timeLeft(from position: Double, rate: Float) -> Double {
        max(stopAt - position, 0) / Double(rate > 0 ? rate : 1)
    }
}
