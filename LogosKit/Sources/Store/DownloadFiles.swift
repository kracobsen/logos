import Foundation

/// Where Downloads keep their audio files: one folder per Book in a backup-excluded directory in Application Support
/// (never Caches, so iOS doesn't evict them), each file at its Server `relPath`. Files get the default data
/// protection, so transfers can finish while the phone is locked after its first unlock.
///
/// Which files are verified is tracked in the database (`downloadFile`), not here. Playback and the launch file check
/// read paths from here too. Safe to use from any thread.
public struct DownloadFiles: Sendable {
    public let directory: URL

    /// Opens the Downloads directory at `directory`, creating it if needed, and marks it excluded from backups.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(excluded)
        self.directory = directory
    }

    /// The Book's folder.
    public func folder(forBook bookID: String) -> URL {
        directory.appending(path: Self.safeName(bookID), directoryHint: .isDirectory)
    }

    /// Where the Book's file with this `relPath` is (or would be). Path components that could leave the Book's
    /// folder (`..`, `.`, empty) are dropped.
    public func url(forBook bookID: String, relPath: String) -> URL {
        let components = relPath.split(separator: "/").map(String.init).filter { !["", ".", ".."].contains($0) }
        var url = folder(forBook: bookID)
        for (index, component) in components.enumerated() {
            url.append(path: component, directoryHint: index == components.count - 1 ? .notDirectory : .isDirectory)
        }
        return url
    }

    /// The size on disk of the Book's file, or `nil` if there's none.
    public func size(ofBook bookID: String, relPath: String) -> Int64? {
        let path = url(forBook: bookID, relPath: relPath).path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Deletes one of the Book's files, if it's there.
    public func delete(bookID: String, relPath: String) {
        try? FileManager.default.removeItem(at: url(forBook: bookID, relPath: relPath))
    }

    /// Deletes the Book's folder and every file in it, partial ones included.
    public func deleteBook(_ bookID: String) {
        try? FileManager.default.removeItem(at: folder(forBook: bookID))
    }

    /// Deletes everything in the directory (signing out); the directory itself stays, empty.
    public func deleteAll() {
        let items =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// The id of every Book with a folder here.
    public func bookIDs() throws -> Set<String> {
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return Set(folders.compactMap { $0.lastPathComponent.removingPercentEncoding })
    }

    private static let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        .intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))

    /// Book ids are UUIDs, but anything else is escaped so it can't leave the directory.
    private static func safeName(_ bookID: String) -> String {
        bookID.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? "book"
    }
}
