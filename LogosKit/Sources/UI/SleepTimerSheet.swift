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

/// The player sheet's Sleep Timer button: "Sleep Timer" unset, the stop Chapter set. Opens the Sleep Timer sheet.
struct SleepTimerButton: View {
    let player: Player
    @State private var isPicking = false

    var body: some View {
        if let book = player.book {
            Button {
                isPicking = true
            } label: {
                if let timer = player.sleepTimer {
                    Label("Chapter \(timer.chapterNumber)", systemImage: "moon.zzz.fill")
                } else {
                    Label("Sleep Timer", systemImage: "moon.zzz")
                }
            }
            .accessibilityLabel("Sleep Timer")
            .accessibilityValue(
                player.sleepTimer.map {
                    SleepTimerText(timer: $0, position: player.position, chapters: book.chapters, rate: player.rate)
                        .projection
                } ?? "Off"
            )
            .sheet(isPresented: $isPicking) {
                SleepTimerSheet(player: player, book: book) { isPicking = false }
                    .presentationDetents([.height(440)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

/// Picks how many Chapters from now the Sleep Timer stops after: a strip of the Book's Chapters showing what will
/// play (tap one to stop there), the stop and its projection, and a −/+ stepper. Start or Update sets it; Cancel
/// clears a set one. A set timer reopens on its stop.
struct SleepTimerSheet: View {
    let player: Player
    let book: BookDetail
    let done: () -> Void
    @State private var count: Int

    init(player: Player, book: BookDetail, done: @escaping () -> Void) {
        self.player = player
        self.book = book
        self.done = done
        _count = State(
            initialValue: SleepTimerPicker.startingCount(
                for: player.sleepTimer, position: player.position, chapters: book.chapters))
    }

    var body: some View {
        let picker = SleepTimerPicker(
            count: count, position: player.position, chapters: book.chapters, bookDuration: book.duration,
            rate: player.rate)
        VStack(spacing: 16) {
            Text("Sleep Timer")
                .font(.headline)
                .padding(.top, 20)
            strip(picker)
            VStack(spacing: 2) {
                Text(picker.stopTitle)
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(picker.text.projection)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            stepper(picker)
            actions(picker)
        }
        .padding(.horizontal, 24)
    }

    private func strip(_ picker: SleepTimerPicker) -> some View {
        let chapters = book.chapters.chapters
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(chapters.indices, id: \.self) { index in
                        bar(index, chapter: chapters[index], picker: picker)
                            .id(index)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(height: 64)
            .padding(.horizontal, -24)
            .onChange(of: picker.stopIndex, initial: true) {
                withAnimation { proxy.scrollTo(picker.stopIndex, anchor: .center) }
            }
        }
        .accessibilityHidden(true)
    }

    /// One Chapter: as wide as it is long (a minute a point, at least 6 so short ones stay tappable), faded once
    /// played, in the accent colour from the one playing to the stop, and marked with a moon at the stop.
    private func bar(_ index: Int, chapter: Chapter, picker: SleepTimerPicker) -> some View {
        let role = picker.role(of: index)
        let color: Color =
            switch role {
            case .played: .secondary.opacity(0.25)
            case .playing, .toPlay: .accentColor
            case .afterStop: .secondary.opacity(0.5)
            }
        return VStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .opacity(index == picker.stopIndex ? 1 : 0)
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(6, chapter.duration / 60), height: role == .playing ? 30 : 22)
        }
        .contentShape(.rect)
        .onTapGesture {
            if let stop = picker.countStopping(at: index) { count = stop }
        }
        .animation(.snappy, value: picker.stopIndex)
    }

    /// The big count between − and +; one adjustable element for VoiceOver in place of the buttons.
    private func stepper(_ picker: SleepTimerPicker) -> some View {
        HStack(spacing: 28) {
            stepButton("minus", enabled: picker.canDecrease) { count = picker.stepped(by: -1) }
            VStack(spacing: 2) {
                Text("\(picker.count)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(picker.count)))
                Text(picker.count <= 1 ? "End of this Chapter" : "Chapters")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Chapters")
            .accessibilityValue(picker.accessibilityValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: count = picker.stepped(by: 1)
                case .decrement: count = picker.stepped(by: -1)
                @unknown default: break
                }
            }
            stepButton("plus", enabled: picker.canIncrease) { count = picker.stepped(by: 1) }
        }
        .animation(.snappy, value: picker.count)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.bold())
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityHidden(true)
    }

    private func actions(_ picker: SleepTimerPicker) -> some View {
        VStack(spacing: 8) {
            Button {
                player.setSleepTimer(chapters: picker.count)
                done()
            } label: {
                Text(player.sleepTimer == nil ? "Start" : "Update")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if player.sleepTimer != nil {
                Button("Cancel Sleep Timer", role: .destructive) {
                    player.cancelSleepTimer()
                    done()
                }
            }
        }
    }
}
