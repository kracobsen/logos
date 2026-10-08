import Domain
import Foundation
import Store
import Testing

@Suite(
    "Series against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct SeriesIntegrationTests {
    @Test("After a sync, the fixture Series has its four Books in reading order, sequences as the Server gives them")
    func fixtureSaga() async throws {
        let session = try await BookDataIntegrationTests.Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }

        #expect(await session.sync.sync(.launch) == .synced)

        let list = try session.database.seriesList()
        #expect(list.map(\.name) == ["Fixture Saga"])
        #expect(list.map(\.bookCount) == [4])
        let page = try #require(try session.database.seriesPage(id: list[0].id))
        #expect(page.books.map(\.title) == ["The First Light", "Between Lights", "Second Dawn", "The Long Dark"])
        #expect(page.books.map(\.sequence) == ["1", "1.5", "2", nil])
    }
}
