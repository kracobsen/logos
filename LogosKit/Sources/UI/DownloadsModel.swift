import Domain
import Downloads
import Foundation
import Observation
import Store

/// What a Book's Download button offers, from its Download (or none).
public enum BookDownloadAction: Sendable, Hashable {
    /// Not downloaded: "Download · 480 MB".
    case download(label: String)
    /// Waiting behind the active Book.
    case queued
    /// The active Book, this far along (0...1).
    case downloading(fraction: Double)
    /// Every file is verified.
    case downloaded
    /// Gave up; downloading again fetches only what's missing.
    case failed
}

/// Downloads for every screen: the Downloaded tab's list and badge, each Book's Download state, and the actions.
///
/// Read from the Store in `init`, then follows it (ADR 0001): the Downloader only writes to the database. One per
/// signed-in identity, shared through the environment.
@Observable
public final class DownloadsModel {
    /// The queue in FIFO order, then the downloaded Books.
    public private(set) var list: DownloadsList
    private var statuses: [String: DownloadStatus]
    /// The cellular setting and the storage pause.
    private var policy: DownloadPolicy
    /// Whether unconstrained Wi-Fi is there (assumed until the network says otherwise).
    public private(set) var isOnWiFi = true

    private let database: AppDatabase
    private let downloader: Downloader?
    private let network: (any NetworkMonitor)?

    /// - Parameters:
    ///   - downloader: does the work. Without it (previews) the actions do nothing.
    ///   - network: for "Waiting for Wi-Fi"; without it, Wi-Fi is assumed.
    public init(database: AppDatabase, downloader: Downloader?, network: (any NetworkMonitor)? = nil) {
        self.database = database
        self.downloader = downloader
        self.network = network
        do {
            list = try database.downloadsList()
            statuses = try database.downloadStatuses()
            policy = try database.downloadPolicy()
        } catch {
            log.error("Couldn't read Downloads: \(String(describing: error), privacy: .public)")
            list = .empty
            statuses = [:]
            policy = .default
        }
    }

    /// Why the queue isn't moving, when there's a known reason: "Not enough storage" or "Waiting for Wi-Fi".
    public var notice: DownloadsNotice? {
        guard list.activeCount > 0 else { return nil }
        if policy.isPausedForStorage { return .notEnoughStorage }
        if !policy.allowsCellular, !isOnWiFi { return .waitingForWiFi }
        return nil
    }

    /// Queued and downloading Books: the Downloaded tab's badge.
    public var badgeCount: Int { list.activeCount }

    /// The space the downloaded Books use, e.g. "1.2 GB".
    public var totalSize: String { Self.size(list.totalBytes) }

    public func status(of bookID: String) -> DownloadStatus? { statuses[bookID] }

    /// The Book's Download button; `size` is the Book's size in bytes, shown on "Download".
    public func action(forBook bookID: String, size: Int64) -> BookDownloadAction {
        guard let status = statuses[bookID] else { return .download(label: "Download · \(Self.size(size))") }
        switch status.state {
        case .queued: return .queued
        case .downloading: return .downloading(fraction: status.fractionDone)
        case .downloaded: return .downloaded
        case .failed: return .failed
        }
    }

    /// Queues the Book's Download (or again, after a failure).
    public func download(_ bookID: String) async {
        await downloader?.download(bookID)
    }

    /// ``download(_:)`` from a button.
    public func startDownload(_ bookID: String) {
        Task { await download(bookID) }
    }

    /// Stops the Book's Download and deletes its files.
    public func cancel(_ bookID: String) async {
        await downloader?.cancel(bookID)
    }

    /// Rebuilds transfers from the database and starts the next Books: after the first frame at launch, and on
    /// every return to the foreground.
    public func resume() async {
        await downloader?.resume()
    }

    public func enteredBackground() async {
        await downloader?.enteredBackground()
    }

    /// Follows Downloads in the database until cancelled.
    public func observe() async {
        await withTaskGroup { group in
            group.addTask { await self.observeList() }
            group.addTask { await self.observeStatuses() }
            group.addTask { await self.observePolicy() }
            group.addTask { await self.observeNetwork() }
        }
    }

    private func observePolicy() async {
        do {
            for try await policy in database.downloadPolicyUpdates() {
                self.policy = policy
            }
        } catch {
            log.error("Stopped observing the Download policy: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeNetwork() async {
        guard let network else { return }
        for await isOnWiFi in network.wifiUpdates() {
            self.isOnWiFi = isOnWiFi
        }
    }

    private func observeList() async {
        do {
            for try await list in database.downloadsListUpdates() {
                self.list = list
            }
        } catch {
            log.error("Stopped observing Downloads: \(String(describing: error), privacy: .public)")
        }
    }

    private func observeStatuses() async {
        do {
            for try await statuses in database.downloadStatusUpdates() {
                self.statuses = statuses
            }
        } catch {
            log.error("Stopped observing Download states: \(String(describing: error), privacy: .public)")
        }
    }

    /// A size in the user's locale, e.g. "480 MB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
