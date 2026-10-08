import Domain
import Foundation
import Playback
import Store

/// A real temporary database and Downloads directory with downloaded Books, a fake player and a test clock.
@MainActor
final class PlayerFixture {
    let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let files: DownloadFiles
    let audio = FakeAudioPlayer()
    let session = FakeAudioSession()

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
    }

    func player() -> Player {
        Player(database: database, files: files, audio: audio, clock: clock, session: session)
    }

    /// Chapters every `chapterLength` seconds over `duration`.
    static func chapters(_ duration: Double, every chapterLength: Double) -> [Chapter] {
        stride(from: 0.0, to: duration, by: chapterLength).enumerated().map { index, start in
            Chapter(id: index, start: start, end: min(start + chapterLength, duration), title: "Chapter \(index + 1)")
        }
    }

    /// Adds a Book to the Library with `fileCount` files splitting `duration` evenly, its Chapters, and (unless
    /// `downloaded` is false) a finished Download with every file on disk.
    func addBook(
        _ id: String,
        duration: Double = 3600,
        fileCount: Int = 2,
        chapters: [Chapter]? = nil,
        downloaded: Bool = true
    ) throws {
        let book = ListedBook(
            id: id, mediaID: "media-\(id)", title: "Title \(id)", subtitle: nil, authorName: "Ada Author",
            authorNameLF: "Author, Ada", narratorName: "", seriesName: "", description: nil, publishedYear: nil,
            genres: [], addedAt: clock.now, updatedAt: 1_700_000_000_000, duration: duration, size: 2000,
            hasCover: false)
        let length = duration / Double(fileCount)
        let tracks = (0..<fileCount).map { index in
            AudioTrack(
                index: index + 1, ino: "ino-\(id)-\(index)", relPath: "Part \(index + 1).m4b", size: 1000,
                duration: length, startOffset: Double(index) * length, mimeType: "audio/mp4")
        }
        let data = BookData(
            book: book, chapters: chapters ?? Self.chapters(duration, every: 600), tracks: tracks, series: [])
        books.append(book)
        try database.applyLibraryList(books, syncedAt: clock.now)
        try database.applyBookData([data])
        guard downloaded else { return }
        for track in tracks {
            let url = files.url(forBook: id, relPath: track.relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 1000).write(to: url)
        }
        try database.queueDownload(ofBook: id)
        _ = try database.startNextDownload()
        try database.setDownloadFiles(tracks, ofBook: id)
        try database.finishDownload(ofBook: id, at: clock.now)
    }

    private var books: [ListedBook] = []

    func fileURLs(_ id: String, count: Int = 2) -> [URL] {
        (0..<count).map { files.url(forBook: id, relPath: "Part \($0 + 1).m4b") }
    }

    func saveProgress(_ id: String, position: Double, at date: Date, isFinished: Bool = false) throws {
        try database.saveProgress(
            BookProgress(bookID: id, position: position, lastChanged: date, isFinished: isFinished))
    }

    func progress(_ id: String) throws -> BookProgress? {
        try database.progress(ofBook: id)
    }

    /// Moves the clock on in quarter-second steps, letting the engine's main-actor tasks run at each step (other
    /// tests keep the main actor busy, so the clock's own yielding isn't enough).
    func advance(by duration: Duration) async {
        await settle()
        var left = duration
        while left > .zero {
            let step = min(left, .milliseconds(250))
            await clock.advance(by: step)
            await settle()
            left -= step
        }
    }

    /// Lets tasks the engine started run to their next suspension point.
    func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }
}
