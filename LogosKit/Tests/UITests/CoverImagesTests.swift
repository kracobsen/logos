import Domain
import Foundation
import Store
import Testing
import UI
import UIKit

@Suite("Cover images")
@MainActor
struct CoverImagesTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let database: AppDatabase
    let files: CoverFiles

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: directory.appending(path: "logos.sqlite"))
        files = try CoverFiles(directory: directory.appending(path: "Covers"))
        try database.applyLibraryList(
            [book("1", updatedAt: 5), book("2", updatedAt: 6)], syncedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// A 600 x 600 px JPEG, like the ones the Server sends.
    static let jpeg: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }()

    func saveCover(_ bookID: String, version: Int64) throws {
        try files.save(Self.jpeg, forBook: bookID)
        try database.setCoverVersion(version, forBook: bookID)
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A row's cover is downscaled to the size asked for")
    func downscales() async throws {
        try saveCover("1", version: 5)
        let images = CoverImages(database: database, files: files)

        let image = try #require(await images.image(forBook: "1", version: 5, maxPixelSize: 132))

        #expect(image.size.width * image.scale == 132)
        #expect(image.size.height * image.scale == 132)
    }

    @Test("A Book without a cover file has no image")
    func noFile() async {
        let images = CoverImages(database: database, files: files)
        #expect(await images.image(forBook: "2", version: 6, maxPixelSize: 132) == nil)
    }

    @Test("A decoded image is available at once afterwards, so a reused row doesn't flash its placeholder")
    func cached() async throws {
        try saveCover("1", version: 5)
        let images = CoverImages(database: database, files: files)
        #expect(images.cachedImage(forBook: "1", maxPixelSize: 132) == nil)

        let decoded = await images.image(forBook: "1", version: 5, maxPixelSize: 132)

        #expect(images.cachedImage(forBook: "1", maxPixelSize: 132) === decoded)
    }

    @Test("Cover versions follow the Store, so a new cover replaces the old image")
    func followsVersions() async throws {
        try saveCover("1", version: 5)
        let images = CoverImages(database: database, files: files)
        #expect(images.version(ofBook: "1") == 5)
        #expect(images.version(ofBook: "2") == nil)
        let observing = Task { await images.observe() }
        defer { observing.cancel() }

        try saveCover("2", version: 6)
        await eventually { images.version(ofBook: "2") == 6 }

        #expect(images.version(ofBook: "2") == 6)
    }

    @Test("A newer version decodes the file again")
    func newVersionDecodesAgain() async throws {
        try saveCover("1", version: 5)
        let images = CoverImages(database: database, files: files)
        let old = await images.image(forBook: "1", version: 5, maxPixelSize: 132)

        let new = await images.image(forBook: "1", version: 7, maxPixelSize: 132)

        #expect(new != nil)
        #expect(new !== old)
    }

    @Test("The launch file check sends a Book whose cover file is missing back to be fetched")
    func fileCheck() async throws {
        try saveCover("1", version: 5)
        files.delete(forBook: "1")
        let images = CoverImages(database: database, files: files)

        await images.checkFiles()

        #expect(try database.coversBehind().map(\.bookID).sorted() == ["1", "2"])
    }

    func book(_ id: String, updatedAt: Int64) -> ListedBook {
        ListedBook(
            id: id, mediaID: "media-\(id)", title: "Book \(id)", subtitle: nil, authorName: "", authorNameLF: "",
            narratorName: "", seriesName: "", description: nil, publishedYear: nil, genres: [],
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: updatedAt, duration: 60, size: 1,
            hasCover: true)
    }
}
