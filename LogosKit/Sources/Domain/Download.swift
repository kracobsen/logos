import Foundation

/// Where a Book's Download is. A Book without a Download has no state at all.
public enum DownloadState: String, Sendable, Hashable, Codable {
    /// Waiting in the queue behind the active Book.
    case queued
    /// The one active Book: its files are being transferred.
    case downloading
    /// Every file is present and verified by size.
    case downloaded
    /// Gave up; the files done so far are kept.
    case failed
}

/// One Book's Download, as Book detail and list rows show it.
public struct DownloadStatus: Sendable, Hashable {
    public let bookID: String
    public let state: DownloadState
    /// The size of every file, in bytes. 0 until the Book's files are known (just after queueing).
    public let totalBytes: Int64
    /// Verified files whole, plus how far the others have got.
    public let receivedBytes: Int64

    public init(bookID: String, state: DownloadState, totalBytes: Int64, receivedBytes: Int64) {
        self.bookID = bookID
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
    }

    /// 0...1; 0 while the size isn't known.
    public var fractionDone: Double {
        totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1) : 0
    }

    /// Queued or downloading: what the Downloaded tab's badge counts.
    public var isActive: Bool { state == .queued || state == .downloading }
}

/// One file of a Download, keyed by the Book id and its `relPath` (the Server's `ino` can change, so it isn't kept).
public struct DownloadFile: Sendable, Hashable {
    public let bookID: String
    public let relPath: String
    /// The Server's `metadata.size`: a file is verified only when the size on disk equals it.
    public var size: Int64
    public var isVerified: Bool
    /// How far the current transfer has got, in bytes (for progress only).
    public var receivedBytes: Int64
    /// What the transfer layer gave back when a transfer stopped part-way, to resume it from there.
    public var resumeData: Data?
    /// Failed transfers of this file (a 401 doesn't count).
    public var attempts: Int
    /// Times the file arrived with the wrong size.
    public var sizeMismatches: Int

    public init(
        bookID: String,
        relPath: String,
        size: Int64,
        isVerified: Bool = false,
        receivedBytes: Int64 = 0,
        resumeData: Data? = nil,
        attempts: Int = 0,
        sizeMismatches: Int = 0
    ) {
        self.bookID = bookID
        self.relPath = relPath
        self.size = size
        self.isVerified = isVerified
        self.receivedBytes = receivedBytes
        self.resumeData = resumeData
        self.attempts = attempts
        self.sizeMismatches = sizeMismatches
    }
}

/// One row of the Downloaded tab.
public struct DownloadRow: Sendable, Hashable, Identifiable {
    /// The Book id.
    public let id: String
    public let title: String
    public let authorName: String
    public let state: DownloadState
    public let totalBytes: Int64
    public let receivedBytes: Int64
    /// A downloaded Book the Server no longer lists: removing its Download deletes the Book.
    public let isNotOnServer: Bool

    public init(
        id: String,
        title: String,
        authorName: String,
        state: DownloadState,
        totalBytes: Int64,
        receivedBytes: Int64,
        isNotOnServer: Bool = false
    ) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.state = state
        self.totalBytes = totalBytes
        self.receivedBytes = receivedBytes
        self.isNotOnServer = isNotOnServer
    }

    public var status: DownloadStatus {
        DownloadStatus(bookID: id, state: state, totalBytes: totalBytes, receivedBytes: receivedBytes)
    }
}

/// The Downloaded tab: the queue in FIFO order (failed Books stay in it), then the downloaded Books, most recently
/// listened first.
public struct DownloadsList: Sendable, Hashable {
    public let queue: [DownloadRow]
    public let downloaded: [DownloadRow]

    public init(queue: [DownloadRow], downloaded: [DownloadRow]) {
        self.queue = queue
        self.downloaded = downloaded
    }

    public static let empty = DownloadsList(queue: [], downloaded: [])

    /// The space the downloaded Books use, in bytes.
    public var totalBytes: Int64 { downloaded.reduce(0) { $0 + $1.totalBytes } }

    /// Queued and downloading Books: the tab badge.
    public var activeCount: Int { queue.count { $0.status.isActive } }
}
