import Domain
import Foundation
import Store
import Testing

@Suite(
    "Library sort and search against the Docker Server",
    .enabled(if: IntegrationServer.isConfigured, "run scripts/integration-test.sh")
)
struct LibrarySearchIntegrationTests {
    @Test(
        "After a sync, search finds Books by narrator and the fixture Series by name, and Author order uses Last, First"
    )
    func fixtureSearch() async throws {
        let session = try await BookDataIntegrationTests.Session()
        defer { try? FileManager.default.removeItem(at: session.directory) }
        #expect(await session.sync.sync(.launch) == .synced)

        let catalog = LibraryCatalog(
            rows: try session.database.libraryRows(), series: try session.database.librarySeries())

        let byNarrator = catalog.results(LibraryQuery(search: "NELL"), progress: [:])
        #expect(
            byNarrator.sections.flatMap(\.rows).map(\.title) == ["Between Lights", "The First Light", "Second Dawn"])

        let bySeries = catalog.results(LibraryQuery(search: "saga"), progress: [:])
        #expect(bySeries.series.map(\.name) == ["Fixture Saga"])
        #expect(bySeries.series.first?.bookIDs.count == 4)
        #expect(bySeries.sections.flatMap(\.rows).count == 4)

        let byAuthor = catalog.results(LibraryQuery(sort: .author), progress: [:])
        #expect(byAuthor.sections.map(\.letter) == ["E", "F"])
    }
}
