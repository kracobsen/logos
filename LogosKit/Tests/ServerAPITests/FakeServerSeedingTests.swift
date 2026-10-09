import Domain
import Foundation
import ServerAPI
import Testing

@Suite("Seeding a signed-in fake Server")
struct FakeServerSeedingTests {
    @Test("Tokens issued without a request work like a sign-in's")
    func issuedTokens() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let server = FakeServer(clock: clock)

        let user = server.issueTokens(for: .listener)

        #expect(user.id == FakeServer.Account.listener.id)
        #expect(server.requests.isEmpty)
        let libraries = try await server.libraries(on: server.address, accessToken: user.tokens.accessToken)
        #expect(libraries.count == 1)
    }
}
