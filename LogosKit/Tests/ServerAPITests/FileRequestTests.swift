import Foundation
import Testing

@testable import ServerAPI

@Suite("File transfer requests")
struct FileRequestTests {
    let server = URL(string: "https://abs.example.com")!

    @Test("A file is an authenticated GET of /api/items/:id/file/:ino")
    func file() {
        let request = Requests.file(ofBook: "item-1", ino: "649484", on: server, accessToken: "access-1")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://abs.example.com/api/items/item-1/file/649484")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
    }

    /// Resume data as URLSession writes it: a property list holding the archived requests and the partial file.
    func resumeData(for request: URLRequest) throws -> Data {
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: request as NSURLRequest, requiringSecureCoding: true)
        let plist: [String: Any] = [
            "NSURLSessionResumeCurrentRequest": archived,
            "NSURLSessionResumeOriginalRequest": archived,
            "NSURLSessionResumeBytesReceived": 1234,
            "NSURLSessionResumeEntityTag": "W/\"4d2-18f\"",
            "NSURLSessionResumeInfoTempFileName": "CFNetworkDownload_abc.tmp",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func requests(in data: Data) throws -> (current: URLRequest?, original: URLRequest?, rest: [String: Any]) {
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        func request(_ key: String) throws -> URLRequest? {
            guard let archived = plist[key] as? Data else { return nil }
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSURLRequest.self, from: archived) as URLRequest?
        }
        return (
            try request("NSURLSessionResumeCurrentRequest"), try request("NSURLSessionResumeOriginalRequest"), plist
        )
    }

    @Test("Resuming points the partial transfer at the fresh ino and token, keeping the partial data and validator")
    func retarget() throws {
        let old = Requests.file(ofBook: "item-1", ino: "111", on: server, accessToken: "old-token")
        let fresh = Requests.file(ofBook: "item-1", ino: "222", on: server, accessToken: "new-token")

        let retargeted = try #require(ResumeData.retargeting(try resumeData(for: old), to: fresh))

        let (current, original, rest) = try requests(in: retargeted)
        for request in [current, original] {
            #expect(request?.url == fresh.url)
            #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
        }
        #expect(rest["NSURLSessionResumeBytesReceived"] as? Int == 1234)
        #expect(rest["NSURLSessionResumeEntityTag"] as? String == "W/\"4d2-18f\"")
        #expect(rest["NSURLSessionResumeInfoTempFileName"] as? String == "CFNetworkDownload_abc.tmp")
    }

    @Test("A file request keeps off cellular unless allowed, and never uses a constrained network")
    func networkPolicy() {
        let wifiOnly = Requests.file(ofBook: "item-1", ino: "1", on: server, accessToken: "a", allowsCellular: false)
        let anyNetwork = Requests.file(ofBook: "item-1", ino: "1", on: server, accessToken: "a", allowsCellular: true)

        #expect(!wifiOnly.allowsCellularAccess)
        #expect(anyNetwork.allowsCellularAccess)
        #expect(!wifiOnly.allowsConstrainedNetworkAccess)
        #expect(!anyNetwork.allowsConstrainedNetworkAccess)
    }

    @Test("Resuming applies the fresh request's network policy")
    func retargetNetworkPolicy() throws {
        let old = Requests.file(ofBook: "item-1", ino: "111", on: server, accessToken: "t", allowsCellular: false)
        let fresh = Requests.file(ofBook: "item-1", ino: "111", on: server, accessToken: "t", allowsCellular: true)

        let retargeted = try #require(ResumeData.retargeting(try resumeData(for: old), to: fresh))

        let (current, original, _) = try requests(in: retargeted)
        #expect(current?.allowsCellularAccess == true)
        #expect(original?.allowsCellularAccess == true)
        #expect(current?.allowsConstrainedNetworkAccess == false)
    }

    @Test("Resume data that can't be read isn't used")
    func unreadable() {
        let fresh = Requests.file(ofBook: "item-1", ino: "222", on: server, accessToken: "new-token")
        #expect(ResumeData.retargeting(Data("not a plist".utf8), to: fresh) == nil)
    }
}
