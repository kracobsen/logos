import Domain
import Foundation

extension Requests {
    /// `POST /api/items/batch/get` with `{"libraryItemIds": [...]}`. Never call it with no ids (the Server says 403).
    static func bookDataBatch(_ ids: [String], on server: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "api/items/batch/get"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["libraryItemIds": ids])
        return request
    }

    /// `GET /api/items/:id?expanded=1`. Without `expanded=1` the Server sends an older shape.
    static func bookData(_ id: String, on server: URL, accessToken: String) -> URLRequest {
        let url = server.appending(path: "api/items").appending(path: id)
            .appending(queryItems: [URLQueryItem(name: "expanded", value: "1")])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension Responses {
    /// Reads `GET /api/items/:id?expanded=1`.
    static func bookData(_ data: Data) throws(ServerAPIError) -> BookData {
        do {
            return try JSONDecoder().decode(ExpandedItem.self, from: data).bookData
        } catch {
            throw .unreadableResponse
        }
    }

    /// Reads `POST /api/items/batch/get`. Lenient per Book: one that can't be read is left out (and stays behind
    /// until it can), so it never blocks the others. Ids the Server doesn't know are simply absent.
    static func bookDataBatch(_ data: Data) throws(ServerAPIError) -> [BookData] {
        struct Body: Decodable {
            let libraryItems: [Lossy]
        }
        struct Lossy: Decodable {
            let item: ExpandedItem?
            init(from decoder: any Decoder) throws {
                item = try? ExpandedItem(from: decoder)
            }
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw .unreadableResponse
        }
        let skipped = body.libraryItems.count { $0.item == nil }
        if skipped > 0 {
            log.notice("Skipped \(skipped) unreadable Books in a batch")
        }
        return body.libraryItems.compactMap { $0.item?.bookData }
    }
}

/// The expanded library item (`LibraryItem.toOldJSONExpanded`): the list fields plus `chapters`, `tracks` and
/// `metadata.series`. `chapters` and `tracks` are required, so a Book is never stored as "no Chapters" by mistake.
private struct ExpandedItem: Decodable {
    struct Media: Decodable {
        struct Metadata: Decodable {
            struct Series: Decodable {
                let id: String
                let name: String
                let sequence: String?
            }
            let title: String
            let subtitle: String?
            let authorName: String?
            let authorNameLF: String?
            let narratorName: String?
            let seriesName: String?
            let description: String?
            let publishedYear: String?
            let genres: [String]?
            let series: [Series]?
        }
        struct Chapter: Decodable {
            let id: Int
            let start: Double
            let end: Double
            let title: String
        }
        struct Track: Decodable {
            struct FileMetadata: Decodable {
                let relPath: String
                let size: Int64
            }
            let index: Int
            let ino: String
            let metadata: FileMetadata
            let duration: Double
            let startOffset: Double
            let mimeType: String?
        }
        let id: String
        let metadata: Metadata
        let coverPath: String?
        let duration: Double?
        let size: Int64?
        let chapters: [Chapter]
        let tracks: [Track]
    }
    let id: String
    let addedAt: Int64
    let updatedAt: Int64
    let media: Media

    var bookData: BookData {
        let metadata = media.metadata
        let book = ListedBook(
            id: id,
            mediaID: media.id,
            title: metadata.title,
            subtitle: metadata.subtitle,
            authorName: metadata.authorName ?? "",
            authorNameLF: metadata.authorNameLF ?? "",
            narratorName: metadata.narratorName ?? "",
            seriesName: metadata.seriesName ?? "",
            description: metadata.description,
            publishedYear: metadata.publishedYear,
            genres: metadata.genres ?? [],
            addedAt: Date(timeIntervalSince1970: TimeInterval(addedAt) / 1000),
            updatedAt: updatedAt,
            duration: media.duration ?? 0,
            size: media.size ?? 0,
            hasCover: media.coverPath != nil
        )
        return BookData(
            book: book,
            chapters: media.chapters.map { Domain.Chapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title) },
            tracks: media.tracks.map {
                AudioTrack(
                    index: $0.index,
                    ino: $0.ino,
                    relPath: $0.metadata.relPath,
                    size: $0.metadata.size,
                    duration: $0.duration,
                    startOffset: $0.startOffset,
                    mimeType: $0.mimeType ?? ""
                )
            },
            series: (metadata.series ?? []).map {
                SeriesMembership(seriesID: $0.id, name: $0.name, sequence: $0.sequence)
            }
        )
    }
}
