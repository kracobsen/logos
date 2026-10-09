/// A Download found damaged (a file missing, the wrong size, or failing to decode) when the listener played it. It's
/// no longer downloaded; its position and Finished are kept.
public struct DamagedDownload: Sendable, Hashable, Identifiable {
    public let bookID: String
    public let title: String
    /// The Server no longer lists the Book, so it can't be downloaded again: only Remove Download is offered.
    public let isNotOnServer: Bool

    public var id: String { bookID }

    public init(bookID: String, title: String, isNotOnServer: Bool) {
        self.bookID = bookID
        self.title = title
        self.isNotOnServer = isNotOnServer
    }
}
