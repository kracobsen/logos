import Domain

/// How a Sleep Timer choice reads: "End of this Chapter" or "3 Chapters", and the projected stop ("Stops at end of
/// Chapter 7 · ~42 min", wall-clock at the playing speed).
struct SleepTimerText: Hashable {
    /// How many Chapters from now, the one playing counting as the first.
    let count: Int
    let title: String
    let projection: String

    init(timer: SleepTimer, position: Double, chapters: ChapterList, rate: Float) {
        count = timer.chapterIndex - chapters.index(at: position) + 1
        title = count <= 1 ? "End of this Chapter" : "\(count) Chapters"
        let left = BookDetailModel.duration(timer.timeLeft(from: position, rate: rate))
        projection = "Stops at end of Chapter \(timer.chapterNumber) · ~\(left)"
    }
}

/// What the Sleep Timer sheet shows for a chosen stop Chapter at the position: the count of Chapters from now (the
/// one playing counting as the first) and its bounds, where each Chapter stands in the strip, and the stop. The
/// sheet holds the stop Chapter rather than the count, so the stop stays put when the next Chapter starts.
struct SleepTimerChoice: Hashable {
    /// The index of the stop Chapter, held to the one playing … the last.
    let stopIndex: Int
    /// The index of the Chapter playing.
    let currentIndex: Int
    /// The index of the Book's last Chapter.
    let lastIndex: Int
    /// The count's title and the projection.
    let text: SleepTimerText
    /// The stop Chapter's title.
    let stopTitle: String

    init(stopIndex: Int, position: Double, chapters: ChapterList, bookDuration: Double, rate: Float) {
        currentIndex = chapters.index(at: position)
        lastIndex = chapters.count - 1
        self.stopIndex = min(max(stopIndex, currentIndex), lastIndex)
        // Held to the one playing … the last Chapter, so there always is one.
        let timer = SleepTimer(
            chapters: self.stopIndex - currentIndex + 1, from: position, in: chapters,
            bookDuration: bookDuration)!
        text = SleepTimerText(timer: timer, position: position, chapters: chapters, rate: rate)
        stopTitle = chapters.chapters[self.stopIndex].title
    }

    /// The stop Chapter the sheet opens on: the set timer's, or the one playing ("End of this Chapter").
    static func startingStop(for timer: SleepTimer?, position: Double, chapters: ChapterList) -> Int {
        timer?.chapterIndex ?? chapters.index(at: position)
    }

    /// How many Chapters from now, the one playing counting as the first.
    var count: Int { text.count }

    /// What VoiceOver reads for the count: "3 Chapters, Stops at end of Chapter 7 · ~42 min".
    var accessibilityValue: String { "\(text.title), \(text.projection)" }

    var canDecrease: Bool { stopIndex > currentIndex }
    var canIncrease: Bool { stopIndex < lastIndex }

    /// The stop Chapter after − (`-1`) or + (`1`), held to its bounds.
    func stepped(by delta: Int) -> Int {
        min(max(stopIndex + delta, currentIndex), lastIndex)
    }
}

extension SleepTimerChoice {
    /// Where a Chapter stands in the strip.
    enum Role: Hashable {
        case played, playing, toPlay, afterStop
    }

    func role(of index: Int) -> Role {
        if index < currentIndex { return .played }
        if index == currentIndex { return .playing }
        return index <= stopIndex ? .toPlay : .afterStop
    }

    /// The stop Chapter after tapping the Chapter at `index`: that one, or `nil` for a Chapter already played.
    func stopIndex(tapping index: Int) -> Int? {
        index >= currentIndex ? min(index, lastIndex) : nil
    }
}
