import Domain
import Foundation
import Testing

@testable import ServerAPI

/// Full Book data (stage 2), decoded from `batch/get` and `items/:id?expanded=1` payloads recorded from 2.37.1.
@Suite("Decoding full Book data")
struct BookDataDecodingTests {
    @Test("An expanded item gives the list data plus Chapters, tracks and Series membership")
    func expandedItem() throws {
        let data = try Responses.bookData(DecodingTests.payload("item-expanded"))

        #expect(data.book.id == "d7c946d8-86c5-49e1-9a58-658fcb01b709")
        #expect(data.book.mediaID == "3fc8d0a4-574b-4c63-b00e-585a3ec797c8")
        #expect(data.book.title == "The First Light")
        #expect(data.book.seriesName == "Fixture Saga #1")
        #expect(data.book.updatedAt == 1_791_466_281_049)
        #expect(data.book.duration == 120)
        #expect(data.book.hasCover)
        #expect(
            data.chapters == [
                Chapter(id: 0, start: 0, end: 40, title: "Dawn"),
                Chapter(id: 1, start: 40, end: 80, title: "Noon"),
                Chapter(id: 2, start: 80, end: 120, title: "Dusk"),
            ]
        )
        #expect(
            data.tracks == [
                AudioTrack(
                    index: 1, ino: "443", relPath: "01.mp3", size: 480_462, duration: 120, startOffset: 0,
                    mimeType: "audio/mpeg")
            ]
        )
        #expect(
            data.series == [
                SeriesMembership(seriesID: "f76924f5-582d-4cba-be2a-dba0086a8d56", name: "Fixture Saga", sequence: "1")
            ]
        )
    }

    @Test("A batch gives every Book it found, in full")
    func batch() throws {
        let books = try Responses.bookDataBatch(DecodingTests.payload("items-batch-get"))
        #expect(books.count == 6)

        let between = try #require(books.first { $0.book.title == "Between Lights" })
        #expect(between.chapters.map(\.title) == ["One", "Two", "Three", "Four"])
        #expect(between.tracks.map(\.relPath) == ["01.mp3", "02.mp3", "03.mp3"])
        #expect(between.tracks.map(\.startOffset) == [0, 60, 120])
        #expect(between.series.map(\.sequence) == ["1.5"])

        let longDark = try #require(books.first { $0.book.title == "The Long Dark" })
        #expect(longDark.series.map(\.name) == ["Fixture Saga"])
        #expect(longDark.series.map(\.sequence) == [nil])

        let plain = try #require(books.first { $0.book.title == "Plain Silence" })
        #expect(plain.chapters.isEmpty)
        #expect(plain.series.isEmpty)
        #expect(plain.tracks.count == 1)
    }

    @Test("One unreadable Book in a batch is skipped; the others still come through")
    func lossyBatch() throws {
        var json = try #require(
            try JSONSerialization.jsonObject(with: DecodingTests.payload("items-batch-get")) as? [String: Any])
        var items = try #require(json["libraryItems"] as? [[String: Any]])
        items[0]["media"] = ["metadata": [:]]
        json["libraryItems"] = items
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(try Responses.bookDataBatch(data).count == 5)
    }

    @Test("A batch response that isn't a batch at all can't be read")
    func unreadableBatch() {
        #expect(throws: ServerAPIError.unreadableResponse) { try Responses.bookDataBatch(Data("[]".utf8)) }
    }
}
