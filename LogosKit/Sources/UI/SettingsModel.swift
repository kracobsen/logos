import Domain
import Downloads
import Observation
import Store

/// The Settings screen's state. Read from the Store in `init`; changes are saved there (ADR 0001).
@Observable
public final class SettingsModel {
    /// "Allow downloads over cellular". Off by default: Downloads use Wi-Fi only.
    public private(set) var allowsCellular: Bool

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
}
