import Foundation

/// The cover files: one ~600 px JPEG per Book, in a directory excluded from backups (the Server can always send them
/// again). A Download shares the same file.
///
/// Which cover a file holds is tracked in the database (the Book's `coverVersion`), not here. Files are written
/// atomically, so a reader sees the old cover or the new one, never part of one. Safe to use from any thread.
public struct CoverFiles: Sendable {
    public let directory: URL

    /// Opens the covers directory at `directory`, creating it if needed, and marks it excluded from backups.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(excluded)
        self.directory = directory
    }

    /// Where the Book's cover is (or would be).
    public func url(forBook bookID: String) -> URL {
        directory.appending(path: Self.fileName(for: bookID), directoryHint: .notDirectory)
    }

    public func exists(forBook bookID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forBook: bookID).path(percentEncoded: false))
    }

    /// Writes the Book's cover, replacing any earlier one.
    public func save(_ data: Data, forBook bookID: String) throws {
        try data.write(to: url(forBook: bookID), options: .atomic)
    }

    /// Deletes the Book's cover, if there is one.
    public func delete(forBook bookID: String) {
        try? FileManager.default.removeItem(at: url(forBook: bookID))
    }

    /// Deletes every cover (signing out); the directory itself stays, empty.
    public func deleteAll() {
        let items =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// The Books that have a cover file.
    public func bookIDs() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        return Set(names.compactMap(Self.bookID(fromFileName:)))
    }

    private static let fileExtension = ".jpg"
    private static let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        .intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))

    /// Book ids are UUIDs, but anything else is escaped so it can't leave the directory.
    private static func fileName(for bookID: String) -> String {
        (bookID.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? bookID) + fileExtension
    }

    private static func bookID(fromFileName name: String) -> String? {
        guard name.hasSuffix(fileExtension) else { return nil }
        return String(name.dropLast(fileExtension.count)).removingPercentEncoding
    }
}
