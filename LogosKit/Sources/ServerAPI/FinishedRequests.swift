import Domain
import Foundation

extension Requests {
    /// `PATCH /api/me/progress/:libraryItemId` with a Finished change, `lastUpdate` = when the listener acted.
    ///
    /// Finished carries the end of the Book as `currentTime` (and the duration): a `currentTime` more than 10 s from
    /// the end would make the Server undo Finished. `finishedAt` is when the listener acted, too. Clearing Finished
    /// sends position 0 (the Server puts a Finished Book at 0 anyway).
    static func updateFinished(_ change: FinishedChange, duration: Double, on server: URL, accessToken: String)
        -> URLRequest
    {
        var request = URLRequest(
            url: server.appending(path: "api/me/progress").appending(path: change.bookID))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let acted = change.lastUpdate.millisecondsSince1970
        let body = FinishedBody(
            isFinished: change.isFinished, currentTime: change.position, duration: duration > 0 ? duration : nil,
            lastUpdate: acted, finishedAt: change.isFinished ? acted : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try? encoder.encode(body)
        return request
    }
}

/// The body of a Finished change's PATCH. Absent fields are left out.
struct FinishedBody: Encodable {
    let isFinished: Bool
    let currentTime: Double
    let duration: Double?
    let lastUpdate: Int64
    let finishedAt: Int64?
}
