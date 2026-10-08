import Domain
import Foundation
import Store
import Testing

@Suite("The Downloads launch file check")
struct DownloadFileCheckTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func open() throws -> (AppDatabase, DownloadFiles) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        try database.applyLibraryList(["a", "b", "c"].map { listedBook($0.uppercased(), id: $0) }, syncedAt: now)
        return (database, try DownloadFiles(directory: directory.appending(path: "Downloads")))
    }

    func track(_ relPath: String) -> AudioTrack {
        AudioTrack(
            index: 1, ino: "ino-\(relPath)", relPath: relPath, size: 10, duration: 60, startOffset: 0,
            mimeType: "audio/mpeg")
    }

    func write(_ files: DownloadFiles, _ bookID: String, _ relPath: String, size: Int = 10) throws {
        let url = files.url(forBook: bookID, relPath: relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: size).write(to: url)
    }

    /// Queues, starts and records the Book's two files, writing and verifying them, then finishes it if `finish`.
    func download(_ bookID: String, _ database: AppDatabase, _ files: DownloadFiles, finish: Bool = true) throws {
        try database.queueDownload(ofBook: bookID)
        #expect(try database.startNextDownload() == bookID)
        try database.setDownloadFiles([track("01.mp3"), track("CD 2/02.mp3")], ofBook: bookID)
        for var file in try database.downloadFiles(ofBook: bookID) {
            try write(files, bookID, file.relPath)
            file.isVerified = true
            try database.saveDownloadFile(file)
        }
        if finish { try database.finishDownload(ofBook: bookID, at: now) }
    }

    @Test("A Download with every file in place stays downloaded")
    func intact() throws {
        let (database, files) = try open()
        try download("a", database, files)

        let check = try database.checkDownloadFiles(files)

        #expect(check == DownloadFileCheck(lostBookIDs: [], deletedBookIDs: []))
        #expect(try database.downloadStatus(ofBook: "a")?.state == .downloaded)
        #expect(files.size(ofBook: "a", relPath: "CD 2/02.mp3") == 10)
    }

    @Test("A Download with a missing or wrong-size file becomes not downloaded, isn't queued again, and its files go")
    func missingFile() throws {
        let (database, files) = try open()
        try download("a", database, files)
        try download("b", database, files)
        try FileManager.default.removeItem(at: files.url(forBook: "a", relPath: "CD 2/02.mp3"))
        try write(files, "b", "01.mp3", size: 3)

        let check = try database.checkDownloadFiles(files)

        #expect(check.lostBookIDs == ["a", "b"])
        #expect(try database.downloadStatus(ofBook: "a") == nil)
        #expect(try database.downloadStatus(ofBook: "b") == nil)
        #expect(try database.downloadQueue().isEmpty)
        #expect(try database.bookIDs() == ["a", "b", "c"])
        #expect(files.size(ofBook: "a", relPath: "01.mp3") == nil)
    }

    @Test("A Not on Server Book whose files are missing is deleted, as when its Download is removed")
    func missingNotOnServer() throws {
        let (database, files) = try open()
        try download("a", database, files)
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)
        try FileManager.default.removeItem(at: files.folder(forBook: "a"))

        let check = try database.checkDownloadFiles(files)

        #expect(check == DownloadFileCheck(lostBookIDs: ["a"], deletedBookIDs: ["a"]))
        #expect(try database.bookIDs() == ["b"])
    }

    @Test("A verified file missing from an unfinished Download is fetched again; folders without a Download go")
    func unfinishedAndOrphans() throws {
        let (database, files) = try open()
        try download("a", database, files, finish: false)
        try FileManager.default.removeItem(at: files.url(forBook: "a", relPath: "01.mp3"))
        try write(files, "c", "01.mp3")

        let check = try database.checkDownloadFiles(files)

        #expect(check == DownloadFileCheck(lostBookIDs: [], deletedBookIDs: []))
        #expect(try database.downloadStatus(ofBook: "a")?.state == .downloading)
        #expect(try database.downloadFiles(ofBook: "a").map(\.isVerified) == [false, true])
        #expect(!FileManager.default.fileExists(atPath: files.folder(forBook: "c").path(percentEncoded: false)))
    }
}
