import Domain
import Playback
import SwiftUI

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

/// The player sheet's Sleep Timer button. Unset, it offers "End of this Chapter", then 2, 3 … Chapters, each with its
/// projected stop. Set, it shows the stop and offers +1 Chapter, Cancel or re-picking.
struct SleepTimerMenu: View {
    let player: Player

    var body: some View {
        if let book = player.book {
            Menu {
                if let timer = player.sleepTimer {
                    let text = text(timer, book)
                    Section(text.projection) {
                        if timer.extended(in: book.chapters, bookDuration: book.duration) != nil {
                            Button("+1 Chapter", systemImage: "plus") { player.extendSleepTimer() }
                        }
                        Button("Cancel Sleep Timer", systemImage: "xmark", role: .destructive) {
                            player.cancelSleepTimer()
                        }
                    }
                    Menu("Change", systemImage: "arrow.triangle.2.circlepath") { options(book) }
                } else {
                    options(book)
                }
            } label: {
                if let timer = player.sleepTimer {
                    Label("Chapter \(timer.chapterNumber)", systemImage: "moon.zzz.fill")
                } else {
                    Label("Sleep Timer", systemImage: "moon.zzz")
                }
            }
            .accessibilityLabel("Sleep Timer")
            .accessibilityValue(player.sleepTimer.map { text($0, book).projection } ?? "Off")
        }
    }

    @ViewBuilder
    private func options(_ book: BookDetail) -> some View {
        ForEach(player.sleepTimerOptions, id: \.chapterIndex) { timer in
            let text = text(timer, book)
            Button {
                player.setSleepTimer(chapters: text.count)
            } label: {
                Text(text.title)
                Text(text.projection)
            }
        }
    }

    private func text(_ timer: SleepTimer, _ book: BookDetail) -> SleepTimerText {
        SleepTimerText(timer: timer, position: player.position, chapters: book.chapters, rate: player.rate)
    }
}
