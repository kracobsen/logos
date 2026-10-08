import Foundation
import Testing

@testable import ServerAPI

@Suite("The logout request")
struct LogOutRequestTests {
    @Test("Logout posts the refresh token in x-refresh-token, with no Authorization, for this device only")
    func logOut() {
        let request = Requests.logOut(URL(string: "https://abs.example.com/abs")!, refreshToken: "refresh-1")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://abs.example.com/abs/logout")
        #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
