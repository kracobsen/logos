import Domain
import Downloads
import Foundation
import ServerAPI
import Store
import Testing

@Suite("Downloads when signing out")
struct SignOutDownloadsTests {
    @Test("Signing out cancels every transfer and backoff, and deletes the whole Downloads directory's contents")
    func signOut() async throws {
        let fixture = try await DownloadsFixture(books: [
            book("a", files: [("01.mp3", 100), ("02.mp3", 100)]), book("b", files: [("01.mp3", 50)]),
            book("c", files: [("01.mp3", 50)]),
        ])
        let downloader = await fixture.downloader()
        await downloader.download("c")
        await fixture.server.transfers.completeAll()
        await downloader.download("a")
        await downloader.download("b")
        await fixture.server.transfers.complete(transfer("a", "01.mp3"))
        await fixture.server.transfers.interrupt(transfer("a", "02.mp3"), receivedBytes: 10)  // backing off
        #expect(try fixture.state("c") == .downloaded)
        #expect(try !fixture.files.bookIDs().isEmpty)

        await downloader.signOut()

        #expect(fixture.pending.isEmpty)
        #expect(await fixture.server.transfers.running().isEmpty)
        #expect(try fixture.files.bookIDs().isEmpty)
        // A backoff ending after sign-out starts nothing.
        let before = fixture.server.requests.count
        await fixture.clock.advance(by: .seconds(60 * 60))
        #expect(fixture.server.requests.count == before)
        #expect(fixture.pending.isEmpty)
    }

    @Test("After signing out, a resume or a Download request starts nothing")
    func staysStopped() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100)])])
        let downloader = await fixture.downloader()
        await downloader.signOut()
        try fixture.database.queueDownload(ofBook: "a")

        await downloader.resume()
        await downloader.download("a")

        #expect(fixture.pending.isEmpty)
        #expect(fixture.fileRequests.isEmpty)
    }
}

@Suite("Downloads in needs sign-in")
struct NeedsSignInDownloadsTests {
    @Test("New Downloads wait in needs sign-in, and start once signed in again")
    func pauseAndResume() async throws {
        let fixture = try await DownloadsFixture(books: [book("a", files: [("01.mp3", 100)])])
        let auth = Auth(
            server: fixture.server.address, api: fixture.server, tokenStore: fixture.tokens, clock: fixture.clock)
        let downloader = Downloader(
            database: fixture.database, api: fixture.server, auth: auth, transfers: fixture.server.transfers,
            files: fixture.files, covers: fixture.covers, clock: fixture.clock, storage: fixture.storage)
        await downloader.start()
        fixture.server.revokeAccessTokens()
        fixture.server.revokeRefreshTokens()

        await downloader.download("a")

        #expect(await auth.needsSignIn)
        #expect(fixture.pending.isEmpty)
        #expect(try fixture.state("a") != .failed)

        let fresh = try await fixture.server.logIn(
            to: fixture.server.address, username: "listener", password: "listenerpass")
        try await auth.signedInAgain(with: fresh.tokens)
        await downloader.resume()
        await fixture.server.transfers.completeAll()

        #expect(try fixture.state("a") == .downloaded)
    }
}
