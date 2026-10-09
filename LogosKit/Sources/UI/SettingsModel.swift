import Domain
import Downloads
import Observation
import Playback
import Store

/// The Settings screen's state. Read from the Store in `init`; changes are saved there (ADR 0001).
@Observable
public final class SettingsModel {
    /// "Allow downloads over cellular". Off by default: Downloads use Wi-Fi only.
    public private(set) var allowsCellular: Bool
    /// Skip back: 10, 15, 30 or 60 s (15 by default).
    public private(set) var skipBack: SkipInterval
    /// Skip forward: 10, 15, 30 or 60 s (30 by default).
    public private(set) var skipForward: SkipInterval
    /// Takes skip changes, so its buttons use them at once. Set by ``LaunchModel``.
    public var player: Player?
    /// Sign out. Set by ``LaunchModel``; without it, Settings has no Sign out.
    public var signOut: SignOutModel?

    private let database: AppDatabase
    private let downloader: Downloader?

    /// - Parameter downloader: applies the cellular setting to transfers in flight. Without it the setting is only
    ///   saved.
    public init(database: AppDatabase, downloader: Downloader?) {
        self.database = database
        self.downloader = downloader
        do {
            allowsCellular = try database.downloadPolicy().allowsCellular
        } catch {
            log.error("Couldn't read the settings: \(String(describing: error), privacy: .public)")
            allowsCellular = DownloadPolicy.default.allowsCellular
        }
        let playback: PlaybackSettings
        do {
            playback = try database.playbackSettings()
        } catch {
            log.error("Couldn't read the skip settings: \(String(describing: error), privacy: .public)")
            playback = .default
        }
        skipBack = playback.skipBack
        skipForward = playback.skipForward
    }

    public func setAllowsCellular(_ allowed: Bool) async {
        allowsCellular = allowed
        if let downloader {
            await downloader.setAllowsCellular(allowed)
            return
        }
        do {
            try database.setAllowsCellularDownloads(allowed)
        } catch {
            log.error("Couldn't save the cellular setting: \(String(describing: error), privacy: .public)")
        }
    }

    /// The intervals a skip can be.
    public static let skipChoices = SkipInterval.allCases

    public func setSkipBack(_ interval: SkipInterval) {
        skipBack = interval
        if let player {
            player.setSkipBackInterval(interval)
            return
        }
        do {
            try database.setSkipBack(interval)
        } catch {
            log.error("Couldn't save Skip back: \(String(describing: error), privacy: .public)")
        }
    }

    public func setSkipForward(_ interval: SkipInterval) {
        skipForward = interval
        if let player {
            player.setSkipForwardInterval(interval)
            return
        }
        do {
            try database.setSkipForward(interval)
        } catch {
            log.error("Couldn't save Skip forward: \(String(describing: error), privacy: .public)")
        }
    }
}
