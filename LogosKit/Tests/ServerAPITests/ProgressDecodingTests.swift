import Domain
import Foundation
import Testing

@testable import ServerAPI

@Suite("Progress from the Server")
struct ProgressDecodingTests {
    @Test("Every Book's progress comes with its position, Finished and the Server's lastUpdate")
    func progress() throws {
        let records = try Responses.progress(DecodingTests.payload("me-progress"))
        #expect(
            records == [
                FetchedProgress(
                    bookID: "19ccbae2-534e-4869-8d18-f31b290323c6",
                    position: 42.5,
                    isFinished: false,
                    lastUpdate: 1_791_466_306_865
                ),
                FetchedProgress(
                    bookID: "4bce66aa-8cea-4e12-baa7-6f65af369614",
                    position: 0,
                    isFinished: true,
                    lastUpdate: 1_791_466_306_883
                ),
            ]
        )
    }

    @Test("Podcast episodes and records without a library item are skipped; one odd record doesn't spoil the rest")
    func skipsWhatIsNotABook() throws {
        let data = Data(
            #"""
            {"mediaProgress":[
              {"libraryItemId":"a","mediaItemType":"book","currentTime":10,"isFinished":false,"lastUpdate":5},
              {"libraryItemId":"p","mediaItemType":"podcastEpisode","currentTime":1,"isFinished":false,"lastUpdate":5},
              {"libraryItemId":null,"mediaItemType":"book","currentTime":1,"isFinished":false,"lastUpdate":5},
              {"libraryItemId":"b","mediaItemType":"book","currentTime":null,"isFinished":true,"lastUpdate":6},
              {"libraryItemId":"c","mediaItemType":"book","currentTime":"x","isFinished":false,"lastUpdate":7}
            ]}
            """#.utf8)
        #expect(
            try Responses.progress(data) == [
                FetchedProgress(bookID: "a", position: 10, isFinished: false, lastUpdate: 5),
                FetchedProgress(bookID: "b", position: 0, isFinished: true, lastUpdate: 6),
            ]
        )
    }

    @Test("A response without the progress list can't be read")
    func unreadable() {
        #expect(throws: ServerAPIError.unreadableResponse) { try Responses.progress(Data("{}".utf8)) }
    }

    @Test("Progress is one authenticated GET of /api/me/progress")
    func request() {
        let request = Requests.progress(URL(string: "https://abs.example.com")!, accessToken: "access-1")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/me/progress")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }
}
