import Foundation
import Store
import Testing

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test("opening a database at a new path creates the file, and it opens again later")
    func opensAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "logos.sqlite")

        _ = try AppDatabase.open(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path()))

        _ = try AppDatabase.open(at: url)
    }

    @Test("a path with spaces (like Application Support) opens")
    func pathWithSpaces() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Application Support \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Logos.sqlite")

        _ = try AppDatabase.open(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
