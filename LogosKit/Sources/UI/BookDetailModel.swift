import Domain
import Foundation
import Observation
import Store
import Sync

/// One Book's detail: cover space, title, author, Series links, "duration · Chapters · size", the description and
/// the Chapter list.
///
/// Read straight from the Store in `init`, so the screen opens with real content in its first frame, then follows
/// the database (ADR 0001). A Book whose full data hasn't arrived yet (early in the first sync) is fetched right away
/// by ``fetchIfNeeded()``.
@Observable
public final class BookDetailModel {
    /// A Series the Book belongs to, as a link.
    public struct SeriesLink: Sendable, Hashable, Identifiable {
        public let seriesID: String
        public let name: String
        /// `"Fixture Saga #1.5"`, or just the name when the Server gives no sequence.
        public let label: String
        public var id: String { seriesID }
    }

    public private(set) var detail: BookDetail?
    /// A fetch of this Book's full data is running.
    public private(set) var isFetching = false
    /// Not started, how far in, or Finished.
    public let progress: BookProgressModel

    public let bookID: String
    let database: AppDatabase
    let sync: LibrarySync

    public init(bookID: String, database: AppDatabase, sync: LibrarySync) {
        self.bookID = bookID
        self.database = database
        self.sync = sync
        var detail: BookDetail?
        do {
            detail = try database.bookDetail(id: bookID)
        } catch {
            log.error("Couldn't read the Book: \(String(describing: error), privacy: .public)")
        }
        progress = BookProgressModel(database: database, bookID: bookID, duration: detail?.duration ?? 0)
        self.detail = detail
    }

    public var seriesLinks: [SeriesLink] {
        (detail?.series ?? []).map { series in
            let label = series.sequence.map { "\(series.name) #\($0)" } ?? series.name
            return SeriesLink(seriesID: series.seriesID, name: series.name, label: label)
        }
    }

    /// Never empty for a stored Book: no Chapters from the Server means one Chapter, the whole Book.
    public var chapters: [Chapter] { detail?.chapters.chapters ?? [] }

    /// "2 h 5 min · 12 Chapters · 1.2 GB" (the size in the user's locale).
    public var summary: String {
        guard let detail else { return "" }
        let count = detail.chapters.count
        return [
            Self.duration(detail.duration),
            count == 1 ? "1 Chapter" : "\(count) Chapters",
            ByteCountFormatter.string(fromByteCount: detail.size, countStyle: .file),
        ].joined(separator: " · ")
    }

    /// The description as plain text.
    public var descriptionText: String? {
        guard let html = detail?.description else { return nil }
        let text = plainText(fromHTML: html)
        return text.isEmpty ? nil : text
    }

    /// Follows the Book in the database until cancelled.
    public func observe() async {
        do {
            for try await detail in database.bookDetailUpdates(id: bookID) {
                self.detail = detail
            }
        } catch {
            log.error("Stopped observing the Book: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetches the Book's full data straight away if it hasn't arrived yet. Fails quietly.
    public func fetchIfNeeded() async {
        guard let detail, !detail.hasCurrentFullData, !detail.isNotOnServer else { return }
        isFetching = true
        defer { isFetching = false }
        await sync.fetchFullDataNow(ofBook: bookID)
    }

    /// "2 h 5 min", or "2 min" under an hour.
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// A Chapter's length with the wall-clock time playing it takes at `speed` in parentheses: "10:00 (6:40)" at
    /// 1.5×, or "10:00" alone where the speed doesn't change it.
    static func chapterLength(_ seconds: Double, speed: Double) -> String {
        let length = clock(seconds)
        guard speed > 0, speed.isFinite else { return length }
        let atSpeed = clock(seconds / speed)
        return atSpeed == length ? length : "\(length) (\(atSpeed))"
    }

    /// A Chapter's length: "4:05", or "1:02:05" from an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

extension LibraryModel {
    /// The detail of one of the Library's Books.
    public func detail(for bookID: String) -> BookDetailModel {
        BookDetailModel(bookID: bookID, database: database, sync: sync)
    }
}

/// Plain text from the Server's HTML description: paragraphs and line breaks kept, tags dropped, entities decoded.
/// Small and synchronous, unlike `NSAttributedString`'s HTML import (WebKit, main thread).
private func plainText(fromHTML html: String) -> String {
    var text = html
    for (pattern, replacement) in [
        (#"(?i)<br\s*/?>"#, "\n"),
        (#"(?i)</(p|div|li|h[1-6])>"#, "\n\n"),
        (#"<[^>]*>"#, ""),
    ] {
        text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    text = decodeEntities(text)
    text = text.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
    var result = ""
    var rest = Substring(text)
    while let ampersand = rest.firstIndex(of: "&") {
        result += rest[..<ampersand]
        let afterAmpersand = rest.index(after: ampersand)
        guard let semicolon = rest[afterAmpersand...].prefix(10).firstIndex(of: ";") else {
            result += "&"
            rest = rest[afterAmpersand...]
            continue
        }
        let name = rest[afterAmpersand..<semicolon]
        var decoded: String?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else if name.hasPrefix("#") {
            decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        } else {
            decoded = named[String(name)]
        }
        if let decoded {
            result += decoded
            rest = rest[rest.index(after: semicolon)...]
        } else {
            result += "&"
            rest = rest[afterAmpersand...]
        }
    }
    return result + rest
}
