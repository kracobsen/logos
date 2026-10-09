import Domain
import Foundation
import Testing

@testable import Store

@Suite("Finished by hand and damaged Downloads in the Store")
struct FinishedAndDamageStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let database: AppDatabase
    let files: DownloadFiles
    let tracks = [
        AudioTrack(
            index: 1, ino: "i1", relPath: "01.mp3", size: 10, duration: 1800, startOffset: 0, mimeType: "audio/mpeg"),
        AudioTrack(
            index: 2, ino: "i2", relPath: "02.mp3", size: 20, duration: 1800.5, startOffset: 1800,
            mimeType: "audio/mpeg"),
    ]

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: now)
    }

    func download(_ id: String) throws {
        try database.queueDownload(ofBook: id)
        _ = try database.startNextDownload()
        try database.setDownloadFiles(tracks, ofBook: id)
        for track in tracks {
            let url = files.url(forBook: id, relPath: track.relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(track.size)).write(to: url)
            var file = try #require(try database.downloadFiles(ofBook: id).first { $0.relPath == track.relPath })
            file.isVerified = true
            try database.saveDownloadFile(file)
        }
        try database.finishDownload(ofBook: id, at: now)
    }

    @Test("Marking Finished by hand puts the position at the end; clearing it puts it at 0")
    func setFinished() throws {
        try database.saveProgress(BookProgress(bookID: "a", position: 100, lastChanged: now - 60, isFinished: false))

        try database.setFinished(true, ofBook: "a", at: now)
        #expect(
            try database.progress(ofBook: "a")
                == BookProgress(bookID: "a", position: 3600.5, lastChanged: now, isFinished: true))

        try database.setFinished(false, ofBook: "a", at: now + 5)
        #expect(
            try database.progress(ofBook: "a")
                == BookProgress(bookID: "a", position: 0, lastChanged: now + 5, isFinished: false))

        try database.setFinished(true, ofBook: "b", at: now)
        #expect(try database.progress(ofBook: "b")?.isFinished == true)
    }

    @Test("A downloaded Book's files are intact only when each is on disk at its recorded size")
    func intact() throws {
        try download("a")
        #expect(try database.hasIntactDownload(ofBook: "a", in: files))
        #expect(try !database.hasIntactDownload(ofBook: "b", in: files))

        try Data(count: 19).write(to: files.url(forBook: "a", relPath: "02.mp3"))
        #expect(try !database.hasIntactDownload(ofBook: "a", in: files))

        try FileManager.default.removeItem(at: files.url(forBook: "a", relPath: "02.mp3"))
        #expect(try !database.hasIntactDownload(ofBook: "a", in: files))
    }

    @Test("A damaged Download goes, with its files; the Book and its progress stay, and nothing is queued")
    func damaged() throws {
        try download("a")
        let progress = BookProgress(bookID: "a", position: 3600.5, lastChanged: now, isFinished: true)
        try database.saveProgress(progress)

        try database.discardDamagedDownload(ofBook: "a", files: files)

        #expect(try database.downloadStatus(ofBook: "a") == nil)
        #expect(try database.downloadQueue().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.folder(forBook: "a").path(percentEncoded: false)))
        #expect(try database.progress(ofBook: "a") == progress)
        #expect(try database.bookDetail(id: "a") != nil)
    }

    @Test("A damaged Not on Server Book stays through later syncs until its Download is removed")
    func damagedNotOnServer() throws {
        try download("a")
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)
        try database.discardDamagedDownload(ofBook: "a", files: files)

        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)
        #expect(try database.bookDetail(id: "a")?.isNotOnServer == true)

        #expect(try database.discardDownload(ofBook: "a"))
        #expect(try database.bookDetail(id: "a") == nil)
    }

    @Test("A damaged Not on Server Book listed again is an ordinary Book without a Download")
    func damagedBackOnServer() throws {
        try download("a")
        try database.applyLibraryList([listedBook("B", id: "b")], syncedAt: now)
        try database.discardDamagedDownload(ofBook: "a", files: files)

        try database.applyLibraryList([listedBook("A", id: "a"), listedBook("B", id: "b")], syncedAt: now)

        #expect(try database.bookDetail(id: "a")?.isNotOnServer == false)
        #expect(try database.downloadStatus(ofBook: "a") == nil)
    }
}
