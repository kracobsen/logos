import Foundation

/// Everything the Book detail screen shows, read from the Store in one go.
///
/// Before the Book's full data has arrived (sync stage 2), it has the list data only: no Series, no tracks, and the
/// whole Book as one Chapter. ``hasCurrentFullData`` says which.
public struct BookDetail: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let authorName: String
    public let narratorName: String
    /// HTML, as the Server stores it.
    public let description: String?
    public let publishedYear: String?
    /// In seconds.
    public let duration: Double
    /// The audio's size in bytes.
    public let size: Int64
    public let hasCover: Bool
    public let series: [SeriesMembership]
    public let chapters: ChapterList
    public let tracks: [AudioTrack]
    /// The full data was fetched at the Book's current `updatedAt`.
    public let hasCurrentFullData: Bool
    /// A downloaded Book the Server no longer lists: its data is frozen.
    public let isNotOnServer: Bool

    public init(
        id: String,
        title: String,
        subtitle: String?,
        authorName: String,
        narratorName: String,
        description: String?,
        publishedYear: String?,
        duration: Double,
        size: Int64,
        hasCover: Bool,
        series: [SeriesMembership],
        chapters: ChapterList,
        tracks: [AudioTrack],
        hasCurrentFullData: Bool,
        isNotOnServer: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.authorName = authorName
        self.narratorName = narratorName
        self.description = description
        self.publishedYear = publishedYear
        self.duration = duration
        self.size = size
        self.hasCover = hasCover
        self.series = series
        self.chapters = chapters
        self.tracks = tracks
        self.hasCurrentFullData = hasCurrentFullData
        self.isNotOnServer = isNotOnServer
    }
}
