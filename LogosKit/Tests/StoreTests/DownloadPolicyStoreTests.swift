import Domain
import Foundation
import Store
import Testing

@Suite("The Download policy in the Store")
struct DownloadPolicyStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }

    func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase.open(at: url)
    }

    @Test("Downloads are Wi-Fi only and not paused until set otherwise")
    func defaults() throws {
        #expect(try open().downloadPolicy() == DownloadPolicy(allowsCellular: false, isPausedForStorage: false))
    }

    @Test("Allowing cellular and the storage pause are kept separately, and survive reopening the database")
    func persists() throws {
        let database = try open()
        try database.setAllowsCellularDownloads(true)
        try database.setDownloadsPausedForStorage(true)
        try database.setDownloadsPausedForStorage(false)

        let reopened = try AppDatabase.open(at: url)

        #expect(try reopened.downloadPolicy() == DownloadPolicy(allowsCellular: true, isPausedForStorage: false))
    }

    @Test("The policy is observed")
    func updates() async throws {
        let database = try open()
        var updates = database.downloadPolicyUpdates().makeAsyncIterator()
        #expect(try await updates.next()?.allowsCellular == false)

        try database.setAllowsCellularDownloads(true)

        #expect(try await updates.next()?.allowsCellular == true)
    }
}
