import Foundation
import Store
import Testing

@Suite("Download files on disk")
struct DownloadFilesTests {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    @Test("The Downloads directory is created and excluded from backups")
    func excludedFromBackup() throws {
        let files = try DownloadFiles(directory: root.appending(path: "Downloads"))
        let values = try files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey, .isDirectoryKey])
        #expect(values.isDirectory == true)
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("A file lives under its Book's folder at its relPath, and never outside the Downloads directory")
    func paths() throws {
        let files = try DownloadFiles(directory: root.appending(path: "Downloads"))
        let inside = files.url(forBook: "item-1", relPath: "CD 1/01 Intro.mp3")
        #expect(inside.path().hasPrefix(files.directory.path()))
        #expect(inside.lastPathComponent == "01 Intro.mp3")
        for hostile in ["../../escape.mp3", "/etc/passwd", "a/../../b.mp3"] {
            let url = files.url(forBook: "../item", relPath: hostile).standardizedFileURL
            #expect(url.path().hasPrefix(files.directory.standardizedFileURL.path()))
        }
    }

    @Test("Sizes come from the disk; deleting a Book removes its folder")
    func sizesAndDelete() throws {
        let files = try DownloadFiles(directory: root.appending(path: "Downloads"))
        let url = files.url(forBook: "item-1", relPath: "CD 1/01.mp3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 42).write(to: url)

        #expect(files.size(ofBook: "item-1", relPath: "CD 1/01.mp3") == 42)
        #expect(files.size(ofBook: "item-1", relPath: "02.mp3") == nil)

        files.deleteBook("item-1")
        #expect(files.size(ofBook: "item-1", relPath: "CD 1/01.mp3") == nil)
    }
}
