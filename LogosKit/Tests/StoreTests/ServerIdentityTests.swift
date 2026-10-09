import Domain
import Foundation
import Store
import Testing

@Suite("Server identity")
struct ServerIdentityTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "logos.sqlite") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let identity = ServerIdentity(
        serverURL: URL(string: "https://abs.example.com")!,
        userID: "user-1",
        username: "listener",
        libraryID: "library-1",
        libraryName: "Audiobooks"
    )

    @Test("A fresh database has no Server identity: signed out")
    func freshIsSignedOut() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try AppDatabase.open(at: url).serverIdentity() == nil)
    }

    @Test("The saved identity survives reopening the database")
    func persists() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try AppDatabase.open(at: url).saveServerIdentity(Self.identity)
        #expect(try AppDatabase.open(at: url).serverIdentity() == Self.identity)
    }

    @Test("Saving again replaces the identity; there is only ever one")
    func replaces() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        try database.saveServerIdentity(Self.identity)
        let other = ServerIdentity(
            serverURL: URL(string: "https://example.com/abs")!,
            userID: "user-2",
            username: "other",
            libraryID: "library-2",
            libraryName: "More"
        )
        try database.saveServerIdentity(other)
        #expect(try database.serverIdentity() == other)
    }

    @Test("Observing the identity gives the current value, then each change")
    func observes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.open(at: url)
        var values = database.serverIdentityUpdates().makeAsyncIterator()
        #expect(try await values.next() == .some(nil))
        try database.saveServerIdentity(Self.identity)
        #expect(try await values.next() == Self.identity)
    }
}
