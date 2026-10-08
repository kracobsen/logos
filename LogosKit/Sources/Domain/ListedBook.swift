import Foundation

/// A Book as the Server's Library list gives it (`GET /api/libraries/:id/items?limit=0`, the minified item).
///
/// This is what stage 1 of the sync applies. It has no Chapters, tracks or Series membership: those come with full
/// Book data in stage 2. `seriesName` is only the Server's display string.
public struct ListedBook: Sendable, Hashable, Identifiable {
    /// The library item id: what every other Server call names the Book by.
    public let id: String
    /// The Book's media id (what listening sessions call `bookId`).
    public let mediaID: String
    public let title: String
    public let subtitle: String?
    public let authorName: String
    /// "Last, First", for Author order.
    public let authorNameLF: String
    public let narratorName: String
    /// e.g. `"Fixture Saga #1.5, Other #2"`, or empty.
    public let seriesName: String
    /// HTML, as the Server stores it.
    public let description: String?
    public let publishedYear: String?
    public let genres: [String]
    public let addedAt: Date
    /// The Server's `updatedAt` in milliseconds. The version the later sync stages compare against; compare for
    /// equality only.
    public let updatedAt: Int64
    /// In seconds.
    public let duration: Double
    /// The audio's size in bytes.
    public let size: Int64
    public let hasCover: Bool

    public init(
        id: String,
        mediaID: String,
        title: String,
        subtitle: String?,
        authorName: String,
        authorNameLF: String,
        narratorName: String,
        seriesName: String,
        description: String?,
        publishedYear: String?,
        genres: [String],
        addedAt: Date,
        updatedAt: Int64,
        duration: Double,
        size: Int64,
        hasCover: Bool
    ) {
        self.id = id
        self.mediaID = mediaID
        self.title = title
        self.subtitle = subtitle
        self.authorName = authorName
        self.authorNameLF = authorNameLF
        self.narratorName = narratorName
        self.seriesName = seriesName
        self.description = description
        self.publishedYear = publishedYear
        self.genres = genres
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.size = size
        self.hasCover = hasCover
    }
}
