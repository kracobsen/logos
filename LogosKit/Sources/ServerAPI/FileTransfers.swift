import Foundation

/// One file of a Download in flight, identified by its Book and `relPath` (the `ino` in the URL can change).
public struct FileTransfer: Sendable, Hashable, Codable {
    public let bookID: String
    public let relPath: String

    public init(bookID: String, relPath: String) {
        self.bookID = bookID
        self.relPath = relPath
    }
}

/// A file to fetch with `GET /api/items/:id/file/:ino`.
public struct FileTransferRequest: Sendable, Hashable {
    public let transfer: FileTransfer
    /// Re-read from a fresh expanded Book just before the request is made.
    public let ino: String
    public let server: URL
    /// Carried by the request itself: background transfers can't call back into ``Auth`` for one.
    public let accessToken: String
    /// Where the body is moved when the Server answers 200 or 206 (replacing any file there).
    public let destination: URL
    /// From the ``FileTransferEvent/failed(_:reason:resumeData:)`` of an earlier try: resume from the bytes it got.
    public let resumeData: Data?

    public init(
        transfer: FileTransfer,
        ino: String,
        server: URL,
        accessToken: String,
        destination: URL,
        resumeData: Data? = nil
    ) {
        self.transfer = transfer
        self.ino = ino
        self.server = server
        self.accessToken = accessToken
        self.destination = destination
        self.resumeData = resumeData
    }
}

/// What happened to a file transfer.
public enum FileTransferEvent: Sendable, Hashable {
    /// The transfer has received this many bytes of the file so far.
    case progress(FileTransfer, receivedBytes: Int64)
    /// The Server answered with `status`. With 200 or 206 the body is already at the request's destination, moved
    /// there inside the completion callback; with any other status nothing is written. `accessToken` is the one the
    /// request carried, so a 401 can be refreshed once for every file that got it.
    case finished(FileTransfer, status: Int, accessToken: String)
    /// No complete response: offline, a timeout, or the transfer was stopped. `resumeData`, when there is some,
    /// resumes from the bytes received so far.
    case failed(FileTransfer, reason: String, resumeData: Data?)
}

/// The background file transfer side of the network seam.
///
/// The real one (``BackgroundFileTransfers``) is one background `URLSession` with a fixed identifier: transfers carry
/// on while Logos is suspended or not running, and their events arrive when it runs again. ``FakeFileTransfers`` is
/// the scripted one (``FakeServer/transfers``). Transfers are identified by ``FileTransfer``; there is at most one
/// per file.
public protocol FileTransfers: AnyObject, Sendable {
    /// Where events go. Events that happen before a handler is set are kept and delivered to it, in order.
    func setEventHandler(_ handler: @escaping @Sendable (FileTransferEvent) async -> Void) async

    /// Starts fetching a file, replacing any transfer of the same file.
    func enqueue(_ request: FileTransferRequest) async

    /// The transfers still in flight, including ones started before this launch.
    func running() async -> Set<FileTransfer>

    /// Stops every transfer of the Book. No events are delivered for them.
    func cancel(bookID: String) async
}
