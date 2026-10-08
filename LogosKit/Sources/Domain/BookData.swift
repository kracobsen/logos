import Foundation

/// One audio file of a Book, in play order, as the Server's expanded item lists it in `tracks[]`.
///
/// Downloads key files on ``relPath``. ``ino`` is the Server's file id (an inode number) for
/// `GET /api/items/:id/file/:ino`; it can change when files are replaced, so re-read it from fresh data before a
/// transfer.
public struct AudioTrack: Sendable, Hashable {
    /// The Server's 1-based track index.
    public let index: Int
    public let ino: String
    /// The file's path inside the Book's folder, e.g. `"01.mp3"`.
    public let relPath: String
    /// In bytes.
    public let size: Int64
    /// In seconds.
    public let duration: Double
    /// Where the file starts, in Book seconds.
    public let startOffset: Double
    public let mimeType: String

    public init(
        index: Int,
        ino: String,
        relPath: String,
        size: Int64,
        duration: Double,
        startOffset: Double,
        mimeType: String
    ) {
        self.index = index
        self.ino = ino
        self.relPath = relPath
        self.size = size
        self.duration = duration
        self.startOffset = startOffset
        self.mimeType = mimeType
    }
}

/// A Book's place in one Series.
public struct SeriesMembership: Sendable, Hashable {
    public let seriesID: String
    public let name: String
    /// As the Server gives it (`"1"`, `"1.5"`, `"1a"`), or `nil`. Display it verbatim.
    public let sequence: String?

    public init(seriesID: String, name: String, sequence: String?) {
        self.seriesID = seriesID
        self.name = name
        self.sequence = sequence
    }
}

/// Full Book data (sync stage 2): the list data as of ``ListedBook/updatedAt``, plus Chapters, tracks and Series
/// membership. Comes from `POST /api/items/batch/get` or `GET /api/items/:id?expanded=1`.
public struct BookData: Sendable, Hashable {
    public let book: ListedBook
    /// As the Server sent them; may be empty (see ``ChapterList``).
    public let chapters: [Chapter]
    /// In play order.
    public let tracks: [AudioTrack]
    public let series: [SeriesMembership]

    public init(book: ListedBook, chapters: [Chapter], tracks: [AudioTrack], series: [SeriesMembership]) {
        self.book = book
        self.chapters = chapters
        self.tracks = tracks
        self.series = series
    }
}
