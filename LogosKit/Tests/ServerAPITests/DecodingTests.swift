import Domain
import Foundation
import Testing

@testable import ServerAPI

/// Decoding against payloads recorded from audiobookshelf 2.37.1 (tokens replaced by unsigned stand-ins with the
/// recorded claims).
@Suite("Decoding recorded 2.37.1 payloads")
struct DecodingTests {
    static func payload(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Payloads"))
        return try Data(contentsOf: url)
    }

    @Test("The Library list gives every Book with its list data")
    func books() throws {
        let books = try Responses.books(Self.payload("library-items"))
        #expect(books.count == 6)
        let first = try #require(books.first { $0.title == "The First Light" })
        #expect(
            first
                == ListedBook(
                    id: "5b8aa451-bf47-4116-b9d5-bab96e27a494",
                    mediaID: "cf01d58e-9b9f-4490-9fbf-caee9e978544",
                    title: "The First Light",
                    subtitle: nil,
                    authorName: "Ada Fixture",
                    authorNameLF: "Fixture, Ada",
                    narratorName: "Nell Narrator",
                    seriesName: "Fixture Saga #1",
                    description: first.description,
                    publishedYear: "2001",
                    genres: ["Fixture"],
                    addedAt: Date(timeIntervalSince1970: 1_791_465_521.154),
                    updatedAt: 1_791_465_521_154,
                    duration: 120,
                    size: 480_462,
                    hasCover: true
                )
        )
        #expect(first.description?.hasPrefix("First Book of the Fixture Saga") == true)
        let plain = try #require(books.first { $0.title == "Plain Silence" })
        #expect(plain.hasCover == false)
        #expect(plain.seriesName == "")
        #expect(plain.narratorName == "")
        #expect(plain.description == nil)
    }

    @Test("A list with a Book missing its id or title can't be read, so it's never applied")
    func undecodableBooks() throws {
        let data = Data(#"{"results":[{"id":"x","addedAt":1,"updatedAt":1,"media":{"metadata":{}}}],"total":1}"#.utf8)
        #expect(throws: ServerAPIError.unreadableResponse) { try Responses.books(data) }
        #expect(throws: ServerAPIError.unreadableResponse) { try Responses.books(Data("[]".utf8)) }
    }

    @Test("Status gives the version and whether local sign-in is allowed")
    func status() throws {
        let status = try Responses.status(Self.payload("status"))
        #expect(status.version == ServerVersion("2.37.1"))
        #expect(status.reportedVersion == "2.37.1")
        #expect(status.allowsLocalSignIn)
    }

    @Test("Status without local sign-in says so")
    func statusWithoutLocal() throws {
        let data = Data(
            #"{"app":"audiobookshelf","serverVersion":"2.37.1","isInit":true,"authMethods":["openid"]}"#.utf8)
        #expect(try Responses.status(data).allowsLocalSignIn == false)
    }

    @Test("Something that isn't audiobookshelf can't be read as a status")
    func notAudiobookshelf() {
        #expect(throws: ServerAPIError.unreadableResponse) {
            try Responses.status(Data("<html>hello</html>".utf8))
        }
    }

    @Test("Login gives the user and the token pair, never the legacy token")
    func logIn() throws {
        let user = try Responses.signedInUser(Self.payload("login"))
        #expect(user.id == "ce5f34dd-cd35-45a3-a131-90f19f1f7db5")
        #expect(user.username == "listener")
        #expect(user.tokens.accessToken.hasPrefix("eyJ"))
        #expect(user.tokens.refreshToken.hasPrefix("eyJ"))
        // The recorded access token was issued at 1791464659 and lives one hour.
        #expect(user.tokens.accessTokenExpiry == Date(timeIntervalSince1970: 1_791_468_259))
        #expect(user.tokens.refreshTokenExpiry == Date(timeIntervalSince1970: 1_794_056_659))
    }

    @Test("Refresh gives the rotated pair")
    func refresh() throws {
        let login = try Responses.signedInUser(Self.payload("login"))
        let refreshed = try Responses.signedInUser(Self.payload("refresh"))
        #expect(refreshed.id == login.id)
        #expect(refreshed.tokens.refreshToken != login.tokens.refreshToken)
        #expect(refreshed.tokens.accessToken != login.tokens.accessToken)
    }

    @Test("A login without a refresh token is unreadable, since Logos never uses the legacy token")
    func missingRefreshToken() {
        let data = Data(#"{"user":{"id":"u","username":"x","token":"legacy","accessToken":"a"}}"#.utf8)
        #expect(throws: ServerAPIError.unreadableResponse) {
            try Responses.signedInUser(data)
        }
    }

    @Test("Libraries come with their media type")
    func libraries() throws {
        let libraries = try Responses.libraries(Self.payload("libraries"))
        #expect(
            libraries == [
                ServerLibrary(id: "0d811c9d-491c-471b-808b-9b8a5c8dab90", name: "Fixtures", mediaType: .book),
                ServerLibrary(id: "3dbbba6c-6a13-4c2c-aeb7-08346d064ac9", name: "Podcasts", mediaType: .podcast),
                ServerLibrary(id: "d153be81-ba4e-4356-9fd2-45fc21e23b10", name: "More Books", mediaType: .book),
            ]
        )
    }
}

@Suite("Token lifetimes from the JWT")
struct TokenPairTests {
    @Test("A token that isn't a readable JWT has no known expiry")
    func unreadable() {
        let pair = TokenPair(accessToken: "not-a-jwt", refreshToken: "a.b.c")
        #expect(pair.accessTokenExpiry == nil)
        #expect(pair.refreshTokenExpiry == nil)
    }

    @Test("The expiry is read from the base64url payload, padding or not")
    func readsExp() {
        // {"exp":1700000000,"sub":"?>?"} has '-'/'_' in base64url and needs padding.
        let token = TestJWT.make(claims: #"{"exp":1700000000,"sub":"?>?"}"#)
        let pair = TokenPair(accessToken: token, refreshToken: token)
        #expect(pair.accessTokenExpiry == Date(timeIntervalSince1970: 1_700_000_000))
    }
}

enum TestJWT {
    static func make(claims: String) -> String {
        func encode(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(#"{"alg":"HS256","typ":"JWT"}"#)).\(encode(claims)).signature"
    }
}
