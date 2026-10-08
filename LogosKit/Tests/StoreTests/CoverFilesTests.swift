import Foundation
import Store
import Testing

@Suite("Cover files")
struct CoverFilesTests {
    let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var directory: URL { parent.appending(path: "Covers") }

    @Test("A saved cover is a file in the covers directory, read back as saved")
    func saves() throws {
        let covers = try CoverFiles(directory: directory)
        try covers.save(Data("jpeg-1".utf8), forBook: "book-1")

        let url = covers.url(forBook: "book-1")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(try Data(contentsOf: url) == Data("jpeg-1".utf8))
        #expect(covers.exists(forBook: "book-1"))
        #expect(!covers.exists(forBook: "book-2"))
    }

    @Test("The covers directory is created and excluded from backups")
    func excludedFromBackup() throws {
        _ = try CoverFiles(directory: directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey, .isDirectoryKey])
        #expect(values.isDirectory == true)
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("Saving again replaces the cover; deleting removes it")
    func replacesAndDeletes() throws {
        let covers = try CoverFiles(directory: directory)
        try covers.save(Data("old".utf8), forBook: "book-1")
        try covers.save(Data("new".utf8), forBook: "book-1")
        #expect(try Data(contentsOf: covers.url(forBook: "book-1")) == Data("new".utf8))

        covers.delete(forBook: "book-1")
        covers.delete(forBook: "never-saved")
        #expect(!covers.exists(forBook: "book-1"))
    }

    @Test("It lists the Books that have a cover file")
    func lists() throws {
        let covers = try CoverFiles(directory: directory)
        try covers.save(Data("a".utf8), forBook: "book-1")
        try covers.save(Data("b".utf8), forBook: "book/2")
        #expect(try covers.bookIDs() == ["book-1", "book/2"])
    }

    @Test("Opening an existing directory keeps its covers")
    func reopens() throws {
        try CoverFiles(directory: directory).save(Data("a".utf8), forBook: "book-1")
        #expect(try CoverFiles(directory: directory).exists(forBook: "book-1"))
    }
}
