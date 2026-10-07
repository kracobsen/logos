// PROTOTYPE — throwaway. Answers wayfinder ticket "Prototype: multi-file playback — composition timeline vs queue player"
// (https://github.com/kracobsen/logos/issues/12).
//
// Plays the same downloaded Book through two engines and logs what each does:
//   Composition · AVMutableComposition single Book timeline on one AVPlayer
//   Queue       · AVQueuePlayer, one item per file, offset table from the Server
// Measured: cold load → ready, play → playing, seek landing error/latency (incl. cross-file, 1–2×),
// file-boundary transitions, gaps/clicks in the test tone, Server vs actual file durations (Chapter drift),
// and both wired into the iOS 27 Now Playing framework (lock screen / Control Center).
//
// Test Books are bundled ("talking clock": voice says the Book time in the left ear, a continuous tone in the
// right ear). Real Books can be pulled from the Server via "Server…".

import AVFoundation
import SwiftUI

@main
struct MultiFilePlaybackPrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            if let run = Autorun.current {
                NavigationStack { PlayerView(book: run.book, engine: run.engine, autorun: true) }
            } else {
                BookListView()
            }
        }
    }
}

/// `-autorun <book id> -engine Queue|Composition`: open that Book, run the scripted pass, print the log to stdout.
enum Autorun {
    static let current: (book: Book, engine: EngineKind)? = {
        let args = UserDefaults.standard
        guard let id = args.string(forKey: "autorun"),
            let book = (BookStore.bundled() + BookStore.downloaded()).first(where: { $0.id == id })
        else { return nil }
        return (book, EngineKind(rawValue: args.string(forKey: "engine") ?? "") ?? .composition)
    }()
    static var isActive: Bool { current != nil }
}

struct BookListView: View {
    @AppStorage("engine") private var engine = EngineKind.composition.rawValue
    @State private var bundled = BookStore.bundled()
    @State private var downloaded = BookStore.downloaded()
    @State private var showServer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Engine", selection: $engine) {
                        ForEach(EngineKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Engine a Book opens with. You can switch inside the player; it keeps the position.")
                }
                Section("Test Books (talking clock)") {
                    ForEach(bundled) { row($0) }
                    if bundled.isEmpty { Text("None bundled: run run.sh to generate them").foregroundStyle(.secondary) }
                }
                Section("Downloaded from the Server") {
                    ForEach(downloaded) { row($0) }
                        .onDelete { offsets in
                            for i in offsets { try? FileManager.default.removeItem(at: downloaded[i].directory) }
                            downloaded = BookStore.downloaded()
                        }
                    Button("Server…") { showServer = true }
                }
            }
            .navigationTitle("Multi-file playback")
            .navigationDestination(for: Book.self) { book in
                PlayerView(book: book, engine: EngineKind(rawValue: engine) ?? .composition)
            }
            .sheet(isPresented: $showServer) {
                NavigationStack { ServerView { downloaded = BookStore.downloaded() } }
            }
        }
    }

    private func row(_ book: Book) -> some View {
        NavigationLink(value: book) {
            VStack(alignment: .leading) {
                Text(book.title)
                Text("\(book.tracks.count) file(s) · \(book.effectiveChapters.count) Chapter(s) · \(clock(book.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlayerView: View {
    @State private var model: PlayerModel
    @State private var jumpText = ""

    private let autorun: Bool

    init(book: Book, engine: EngineKind, autorun: Bool = false) {
        self.autorun = autorun
        _model = State(initialValue: PlayerModel(book: book, engine: engine))
    }

    var body: some View {
        List {
            Section {
                Picker("Engine", selection: Binding(get: { model.engineKind }, set: { k in Task { await model.switchEngine(to: k) } })) {
                    ForEach(EngineKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                state
                transport
            }
            Section("Speed") {
                Picker("Speed", selection: $model.rate) {
                    ForEach([1.0, 1.25, 1.5, 2.0, 3.0] as [Float], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Time-pitch", selection: $model.algorithm) {
                    Text("Time domain").tag(AVAudioTimePitchAlgorithm.timeDomain)
                    Text("Spectral").tag(AVAudioTimePitchAlgorithm.spectral)
                }
                .pickerStyle(.segmented)
            }
            Section("Tests") {
                HStack {
                    Button("◀︎ boundary") { Task { await model.jumpToBoundary(forward: false) } }
                    Spacer()
                    Button("Next boundary ▶︎") { Task { await model.jumpToBoundary(forward: true) } }
                }
                .buttonStyle(.borderless)
                HStack {
                    TextField("Go to (m:ss or h:mm:ss)", text: $jumpText).keyboardType(.numbersAndPunctuation)
                    Button("Go") { if let t = parse(jumpText) { Task { await model.seek(to: t) } } }.buttonStyle(.borderless)
                }
                Button("Run seek test (≈1 min)") { Task { await model.runSeekTest() } }
                    .disabled(model.isBusy)
                Toggle("Lock screen shows Chapter progress", isOn: $model.chapterScopedLockScreen)
            }
            Section("Chapters") {
                ForEach(Array(model.book.effectiveChapters.enumerated()), id: \.offset) { i, c in
                    Button {
                        Task { await model.seekToChapter(i) }
                    } label: {
                        HStack {
                            Text(c.title).fontWeight(i == model.chapterIndex ? .bold : .regular)
                            Spacer()
                            Text("\(clock(c.start)) · file \(model.book.trackIndex(at: c.start) + 1)").font(.caption.monospaced())
                        }
                    }
                }
            }
            Section {
                ForEach(model.log.reversed()) { Text($0.text).font(.caption2.monospaced()).textSelection(.enabled) }
            } header: {
                HStack {
                    Text("Log (newest first)")
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = model.log.map(\.text).joined(separator: "\n") }
                }
            }
        }
        .navigationTitle(model.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if autorun { Task { await model.autorun() } }
            await model.start()
        }
        .onDisappear { model.stop() }
    }

    private var state: some View {
        let book = model.book
        let chapter = book.effectiveChapters[model.chapterIndex]
        let file = book.tracks[min(model.fileIndex, book.tracks.count - 1)]
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(clock(model.currentTime)) / \(clock(book.duration))").font(.title2.monospacedDigit())
            Text("Chapter \(model.chapterIndex + 1)/\(book.effectiveChapters.count) “\(chapter.title)” · \(clock(model.currentTime - chapter.start)) in")
            Text("File \(model.fileIndex + 1)/\(book.tracks.count) · \(clock(model.currentTime - file.startOffset)) into \(file.file)")
            Text("\(model.status)\(model.isBusy ? " · busy" : "")").foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
    }

    private var transport: some View {
        HStack {
            Button { Task { await model.skip(-15) } } label: { Image(systemName: "gobackward.15") }
            Spacer()
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle) }
            Spacer()
            Button { Task { await model.skip(30) } } label: { Image(systemName: "goforward.30") }
        }
        .buttonStyle(.borderless)
        .font(.title)
        .padding(.horizontal, 40)
        .disabled(model.status == "loading")
    }

    private func parse(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
