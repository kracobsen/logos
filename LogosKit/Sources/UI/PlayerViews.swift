import Domain
import Playback
import SwiftUI

/// A downloaded Book's primary action: Play, Resume or Pause. Full width on Book detail, an icon on In Progress rows.
struct PlayButton: View {
    let bookID: String
    var resumes = false
    var compact = false
    @Environment(Player.self) private var player: Player?

    var body: some View {
        if let player {
            let action = player.action(forBook: bookID, resumes: resumes)
            Button {
                player.tapped(bookID: bookID)
            } label: {
                if compact {
                    Image(systemName: action == .pause ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                } else {
                    Label(action.title, systemImage: action.systemImage)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityLabel(action.title)
            .modifier(FullWidthProminent(isOn: !compact))
        }
    }
}

private struct FullWidthProminent: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content
        }
    }
}

/// The mini-player, the tab view's bottom accessory: cover, Chapter and Book, and Play/Pause. Tapping it opens the
/// full player.
struct MiniPlayerView: View {
    let player: Player
    let open: () -> Void

    var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        CoverView(bookID: book.id, side: 32, cornerRadius: 4)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(book.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(player.pickedUp.map(PickUpNotice.text) ?? player.chapter?.title ?? book.authorName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the player")
                if player.pickedUp != nil {
                    Button("Undo") { player.undoPickUp() }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHint("Goes back to where this iPhone was")
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(player.state == .loading)
            }
            .padding(.horizontal, 16)
        }
    }
}

/// The full player sheet: cover, Chapter name, Book title and author; a Chapter-scoped scrubber with elapsed and left;
/// a thin whole-Book line with "left in Book"; skip back / Play-Pause / skip forward; and the Chapters list.
struct PlayerSheet: View {
    let player: Player
    @State private var scrubbing: Double?
    @State private var showsChapters = false

    var body: some View {
        if let book = player.book {
            let times = PlaybackTimes(
                position: scrubbing ?? player.position, chapters: book.chapters, bookDuration: book.duration)
            VStack(spacing: 20) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
                PickUpBanner(player: player)
                Spacer(minLength: 0)
                CoverView(bookID: book.id, side: 300, cornerRadius: 10)
                VStack(spacing: 4) {
                    Text(times.chapter.title)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(book.authorName.isEmpty ? book.title : "\(book.title) · \(book.authorName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                scrubber(times)
                bookLine(times)
                controls
                Button {
                    showsChapters = true
                } label: {
                    Label("Chapters", systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .sheet(isPresented: $showsChapters) {
                ChaptersList(player: player, chapters: book.chapters.chapters) { showsChapters = false }
            }
        }
    }

    private func scrubber(_ times: PlaybackTimes) -> some View {
        let chapter = times.chapter
        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubbing ?? player.position },
                    set: { scrubbing = $0 }
                ),
                in: chapter.start...max(chapter.end, chapter.start + 0.001)
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            .accessibilityLabel("Position in Chapter")
            .accessibilityValue(BookDetailModel.clock(times.chapterElapsed))
            HStack {
                Text(BookDetailModel.clock(times.chapterElapsed))
                Spacer()
                Text("-\(BookDetailModel.clock(times.chapterLeft))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func bookLine(_ times: PlaybackTimes) -> some View {
        VStack(spacing: 4) {
            ProgressView(value: times.bookFraction)
                .progressViewStyle(.linear)
                .scaleEffect(x: 1, y: 0.5, anchor: .center)
            Text("\(timeLeftText(times.bookLeft)) in Book")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button {
                player.skip(by: -SkipIntervals.back)
            } label: {
                Image(systemName: "gobackward.\(Int(SkipIntervals.back))")
                    .font(.title)
            }
            .accessibilityLabel("Skip back \(Int(SkipIntervals.back)) seconds")
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(player.state == .loading)
            Button {
                player.skip(by: SkipIntervals.forward)
            } label: {
                Image(systemName: "goforward.\(Int(SkipIntervals.forward))")
                    .font(.title)
            }
            .accessibilityLabel("Skip forward \(Int(SkipIntervals.forward)) seconds")
        }
        .buttonStyle(.plain)
    }
}

/// The loaded Book's Chapters with durations, the current one highlighted; tapping one jumps there.
struct ChaptersList: View {
    let player: Player
    let chapters: [Chapter]
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    let isCurrent = index == player.chapterIndex
                    Button {
                        player.jump(toChapter: index)
                        done()
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .lineLimit(2)
                            Spacer()
                            Text(BookDetailModel.clock(chapter.duration))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    .id(chapter.id)
                }
                .listStyle(.plain)
                .onAppear {
                    if let index = player.chapterIndex { proxy.scrollTo(chapters[index].id, anchor: .center) }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
    }
}

/// One of Book detail's Chapters with its duration. When the Book is downloaded, tapping it plays from the Chapter's
/// start; the Chapter playing is highlighted.
struct BookChapterRow: View {
    let bookID: String
    let index: Int
    let chapter: Chapter
    @Environment(DownloadsModel.self) private var downloads: DownloadsModel?
    @Environment(Player.self) private var player: Player?

    var body: some View {
        let isCurrent = player?.book?.id == bookID && player?.chapterIndex == index
        if let player, downloads?.status(of: bookID)?.state == .downloaded {
            Button {
                Task { await player.play(bookID: bookID, from: chapter.start) }
            } label: {
                row(isCurrent: isCurrent)
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .accessibilityHint("Plays from this Chapter")
        } else {
            row(isCurrent: false)
        }
    }

    private func row(isCurrent: Bool) -> some View {
        HStack {
            Text(chapter.title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(2)
            Spacer()
            Text(BookDetailModel.clock(chapter.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
