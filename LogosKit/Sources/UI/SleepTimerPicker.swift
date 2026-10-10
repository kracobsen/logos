import Domain

/// What the Sleep Timer sheet shows for a count of Chapters from now (the one playing counting as the first): the
/// count's bounds, where each Chapter stands in the strip, and the stop.
struct SleepTimerPicker: Hashable {
    /// How many Chapters from now, held to 1 … the last Chapter.
    let count: Int
    /// The index of the Chapter playing.
    let currentIndex: Int
    /// The most Chapters that can be chosen: from the one playing to the last.
    let maxCount: Int
    /// The Sleep Timer that Start or Update sets.
    let timer: SleepTimer
    /// The stop Chapter's title and the projection.
    let text: SleepTimerText
    let stopTitle: String

    init(count: Int, position: Double, chapters: ChapterList, bookDuration: Double, rate: Float) {
        currentIndex = chapters.index(at: position)
        maxCount = chapters.count - currentIndex
        self.count = min(max(count, 1), maxCount)
        // Held to 1 … the last Chapter, so there always is one.
        timer = SleepTimer(chapters: self.count, from: position, in: chapters, bookDuration: bookDuration)!
        text = SleepTimerText(timer: timer, position: position, chapters: chapters, rate: rate)
        stopTitle = chapters.chapters[timer.chapterIndex].title
    }

    /// The count the sheet opens on: the set timer's, or "End of this Chapter".
    static func startingCount(for timer: SleepTimer?, position: Double, chapters: ChapterList) -> Int {
        guard let timer else { return 1 }
        return max(timer.chapterIndex - chapters.index(at: position) + 1, 1)
    }

    /// The index of the stop Chapter: the last one that plays.
    var stopIndex: Int { currentIndex + count - 1 }

    /// What VoiceOver reads for the count: "3 Chapters, Stops at end of Chapter 7 · ~42 min".
    var accessibilityValue: String { "\(text.title), \(text.projection)" }

    var canDecrease: Bool { count > 1 }
    var canIncrease: Bool { count < maxCount }

    /// The count after − (`-1`) or + (`1`), held to its bounds.
    func stepped(by delta: Int) -> Int {
        min(max(count + delta, 1), maxCount)
    }
}

extension SleepTimerPicker {
    /// Where a Chapter stands in the strip.
    enum Role: Hashable {
        case played, playing, toPlay, afterStop
    }

    func role(of index: Int) -> Role {
        if index < currentIndex { return .played }
        if index == currentIndex { return .playing }
        return index <= stopIndex ? .toPlay : .afterStop
    }

    /// The count that stops at the end of the Chapter at `index`, or `nil` for a Chapter already played.
    func countStopping(at index: Int) -> Int? {
        index >= currentIndex ? min(index - currentIndex + 1, maxCount) : nil
    }
}
