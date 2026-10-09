import Foundation

extension Requests {
    /// `GET /api/items/:id/file/:ino`: one audio file. The Server answers Range requests (206) and `If-Range`.
    /// Off cellular unless `allowsCellular`, and never on a constrained network (Low Data Mode).
    static func file(
        ofBook bookID: String, ino: String, on server: URL, accessToken: String, allowsCellular: Bool = false
    ) -> URLRequest {
        let url = server.appending(path: "api/items").appending(path: bookID).appending(path: "file")
            .appending(path: ino)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = false
        return request
    }
}

/// URLSession's resume data for a download that stopped part-way.
///
/// Resuming from it sends `Range` with `If-Range` (the ETag or Last-Modified the first response gave), so the Server
/// sends the rest only if the file hasn't changed, and the whole file otherwise. The data also holds the request it
/// was made for. A Download re-reads the file's `ino` before every resume and may have a fresher token, so the
/// request inside is pointed at the new URL and token first.
enum ResumeData {
    private static let requestKeys = ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"]

    /// `data` with its requests replaced by `request`'s URL, `Authorization` and network policy, or `nil` if it can't be read (then
    /// the file is downloaded from the start).
    static func retargeting(_ data: Data, to request: URLRequest) -> Data? {
        guard
            var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            requestKeys.contains(where: { plist[$0] is Data })
        else { return nil }
        for key in requestKeys {
            guard let archived = plist[key] as? Data else { continue }
            guard
                let stored = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURLRequest.self, from: archived),
                var updated = stored as URLRequest?
            else { return nil }
            updated.url = request.url
            updated.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            updated.allowsCellularAccess = request.allowsCellularAccess
            updated.allowsConstrainedNetworkAccess = request.allowsConstrainedNetworkAccess
            guard
                let rearchived = try? NSKeyedArchiver.archivedData(
                    withRootObject: updated as NSURLRequest, requiringSecureCoding: true)
            else { return nil }
            plist[key] = rearchived
        }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }
}
