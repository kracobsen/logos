import Domain
import Downloads
import Foundation
import Observation
import Playback
import Store
import Sync

/// Sign out, from Settings. In order:
/// 1. try to send the outbox (listening sessions and Finished changes);
/// 2. ask to confirm, stating the Downloads count and size and any listening that couldn't be sent;
/// 3. stop playback, stop Downloads, best-effort `POST /logout`, clear the tokens;
/// 4. wipe the database, Downloads and covers, and let the app drop its per-identity objects.
///
/// The app is left like a fresh install: the identity goes with the wipe, so launch shows sign-in.
@Observable
public final class SignOutModel {
    public enum Step: Sendable, Hashable {
        case idle
        /// Trying to send the outbox before asking.
        case sending
        /// Waiting for the listener to confirm, with what will be removed.
        case confirming(SignOutSummary)
        case signingOut
        case signedOut
        /// Something couldn't be read or wiped.
        case failed(String)
    }

    public private(set) var step: Step = .idle

    private let database: AppDatabase
    private let sync: LibrarySync
    private let downloader: Downloader?
    private let player: Player?
    private let covers: CoverFiles?
    private let onSignedOut: (() -> Void)?

    /// - Parameter onSignedOut: after the wipe; the app drops the identity's `Auth` and Downloads there.
    public init(
        database: AppDatabase, sync: LibrarySync, downloader: Downloader?, player: Player?, covers: CoverFiles?,
        onSignedOut: (() -> Void)? = nil
    ) {
        self.database = database
        self.sync = sync
        self.downloader = downloader
        self.player = player
        self.covers = covers
        self.onSignedOut = onSignedOut
    }

    /// Steps 1 and 2: sends what it can, then asks to confirm.
    public func start() async {
        guard step == .idle || isFailed else { return }
        step = .sending
        // Paused, so the latest position is in the session that's sent.
        player?.pause()
        let outcome = await sync.outbox.send()
        log.info("Sign-out: outbox send \(String(describing: outcome), privacy: .public)")
        do {
            step = .confirming(try database.signOutSummary())
        } catch {
            log.error("Sign-out: couldn't read what would be removed: \(String(describing: error), privacy: .public)")
            step = .failed("Couldn't read what's on this iPhone. Try again.")
        }
    }

    public func cancel() {
        guard case .confirming = step else { return }
        step = .idle
    }

    /// Steps 3 and 4.
    public func confirm() async {
        guard case .confirming = step else { return }
        step = .signingOut
        player?.signOut()
        await downloader?.signOut()
        await sync.connection.signOut()
        covers?.deleteAll()
        do {
            try database.wipe()
        } catch {
            log.error("Sign-out: the wipe failed: \(String(describing: error), privacy: .public)")
            step = .failed("Couldn't remove everything. Try signing out again.")
            return
        }
        player?.reloadSettings()
        onSignedOut?()
        step = .signedOut
    }

    private var isFailed: Bool {
        if case .failed = step { true } else { false }
    }

    /// The confirmation's text: what goes from this iPhone, and any listening that would be lost.
    public static func message(for summary: SignOutSummary) -> String {
        var parts: [String] = []
        if summary.downloadCount > 0 {
            let noun = summary.downloadCount == 1 ? "Download" : "Downloads"
            parts.append(
                "\(summary.downloadCount) \(noun) (\(DownloadsModel.size(summary.downloadBytes))) will be removed "
                    + "from this iPhone.")
        }
        var lost: [String] = []
        if summary.unsentSessionCount > 0 {
            let noun = summary.unsentSessionCount == 1 ? "listening session" : "listening sessions"
            lost.append("\(summary.unsentSessionCount) \(noun)")
        }
        if summary.unsentFinishedChangeCount > 0 {
            let noun = summary.unsentFinishedChangeCount == 1 ? "Finished change" : "Finished changes"
            lost.append("\(summary.unsentFinishedChangeCount) \(noun)")
        }
        if !lost.isEmpty {
            parts.append("\(lost.joined(separator: " and ")) couldn't be sent to the Server and will be lost.")
        }
        parts.append("Your Library, progress and settings on this iPhone are removed; sign in to start again.")
        return parts.joined(separator: " ")
    }
}
