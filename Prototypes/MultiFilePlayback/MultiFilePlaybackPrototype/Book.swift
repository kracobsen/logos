// PROTOTYPE — throwaway. A downloaded Book as the player sees it: audio files on disk plus the Server's
// track offsets and Chapters. Stored as `<id>.book.json` next to the files (bundled test Books) or in
// Documents/Books/<id>/ (Books downloaded from the Server).

import Foundation

struct Book: Codable, Identifiable, Hashable {
    struct Track: Codable, Hashable {
        var file: String
        var startOffset: Double  // seconds into the Book, as the Server reports it
        var duration: Double  // as the Server reports it
    }
    struct Chapter: Codable, Hashable {
        var title: String
        var start: Double
        var end: Double
    }

    var id: String
    var title: String
    var author: String
    var duration: Double
    var hasToneChannel: Bool?
    var tracks: [Track]
    var chapters: [Chapter]

    /// Directory the track files live in. Not part of the manifest.
    var directory: URL = URL(fileURLWithPath: "/")

    enum CodingKeys: String, CodingKey { case id, title, author, duration, hasToneChannel, tracks, chapters }

    func url(of track: Track) -> URL { directory.appendingPathComponent(track.file) }

    /// A Book the Server reports no Chapters for is a single Chapter.
    var effectiveChapters: [Chapter] {
        chapters.isEmpty ? [Chapter(title: title, start: 0, end: duration)] : chapters
    }

    func chapterIndex(at time: Double) -> Int {
        effectiveChapters.lastIndex { $0.start <= time + 0.001 } ?? 0
    }

    func trackIndex(at time: Double) -> Int {
        tracks.lastIndex { $0.startOffset <= time + 0.001 } ?? 0
    }
}

enum BookStore {
    static var downloadsRoot: URL {
        URL.documentsDirectory.appendingPathComponent("Books", isDirectory: true)
    }

    static func bundled() -> [Book] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(".book.json") }.compactMap(load).sorted { $0.title < $1.title }
    }

    static func downloaded() -> [Book] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: downloadsRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load($0.appendingPathComponent("book.json")) }.sorted { $0.title < $1.title }
    }

    static func load(_ url: URL) -> Book? {
        guard let data = try? Data(contentsOf: url), var book = try? JSONDecoder().decode(Book.self, from: data) else { return nil }
        book.directory = url.deletingLastPathComponent()
        return book
    }

    static func save(_ book: Book) throws {
        try JSONEncoder().encode(book).write(to: book.directory.appendingPathComponent("book.json"))
    }
}

func clock(_ t: Double) -> String {
    guard t.isFinite else { return "--:--" }
    let s = max(0, t)
    let h = Int(s) / 3600, m = Int(s) / 60 % 60
    let sec = s.truncatingRemainder(dividingBy: 60)
    return h > 0 ? String(format: "%d:%02d:%04.1f", h, m, sec) : String(format: "%d:%04.1f", m, sec)
}
