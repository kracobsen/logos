import Foundation
import ImageIO
import Observation
import Store
import UIKit

/// Cover images for the UI: decoded and downscaled off the main thread, and kept in a small memory cache.
///
/// It follows each Book's cover version in the Store (read at once in `init`, so the first frame already knows which
/// Books have a cover), so a cover that arrives or changes during a sync shows up in rows that are on screen. Views
/// use ``CoverView``, which finds this object in the environment.
@Observable
public final class CoverImages {
    /// Book id -> the version of its cover file. A Book that isn't here has no cover (yet).
    private var versions: [String: Int64]

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let files: CoverFiles
    /// Decoded images by Book id and pixel size. Bounded, so browsing a big Library stays within the memory budget.
    @ObservationIgnored private let cache: NSCache<NSString, CachedCover> = {
        let cache = NSCache<NSString, CachedCover>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    public init(database: AppDatabase, files: CoverFiles) {
        self.database = database
        self.files = files
        do {
            versions = try database.coverVersions()
        } catch {
            log.error("Couldn't read the cover versions: \(String(describing: error), privacy: .public)")
            versions = [:]
        }
    }

    /// The version of the Book's cover file, or `nil` if it has none yet.
    public func version(ofBook bookID: String) -> Int64? {
        versions[bookID]
    }

    /// The image already decoded for the Book at this size, of whatever version, or `nil`. Never decodes.
    public func cachedImage(forBook bookID: String, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Self.key(bookID, maxPixelSize))?.image
    }

    /// The Book's cover at `version`, at most `maxPixelSize` px on its longer side. Decodes on a background thread
    /// unless that version is already cached. `nil` if there's no readable file.
    public func image(forBook bookID: String, version: Int64, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(bookID, maxPixelSize)
        if let cached = cache.object(forKey: key), cached.version == version {
            return cached.image
        }
        guard let image = await Self.decode(files.url(forBook: bookID), maxPixelSize: maxPixelSize) else {
            return nil
        }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
        cache.setObject(CachedCover(version: version, image: image), forKey: key, cost: cost)
        return image
    }

    /// Follows the cover versions in the Store until cancelled.
    public func observe() async {
        do {
            for try await versions in database.coverVersionUpdates() {
                self.versions = versions
            }
        } catch {
            log.error("Stopped observing the cover versions: \(String(describing: error), privacy: .public)")
        }
    }

    /// The launch file check for covers, in the background: a Book whose cover file is missing (say, after a
    /// restore) is sent back to be fetched at the next sync. Call after the first frame, never on the launch path.
    public func checkFiles() async {
        let database = database
        let files = files
        await Task.detached(priority: .utility) {
            do {
                try database.checkCoverFiles(files)
            } catch {
                log.error("The cover file check failed: \(String(describing: error), privacy: .public)")
            }
        }.value
    }

    private static func key(_ bookID: String, _ maxPixelSize: Int) -> NSString {
        "\(maxPixelSize)/\(bookID)" as NSString
    }

    /// Reads a downscaled image straight from the file with ImageIO, never decoding the full-size image.
    @concurrent
    nonisolated private static func decode(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

private final class CachedCover {
    let version: Int64
    let image: UIImage

    init(version: Int64, image: UIImage) {
        self.version = version
        self.image = image
    }
}
