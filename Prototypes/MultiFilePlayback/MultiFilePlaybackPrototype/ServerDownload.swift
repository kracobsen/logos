// PROTOTYPE — throwaway. Just enough of the Server to pull a real Book's audio files onto the device:
// sign in (tokens kept in memory only), pick a Book, download its tracks + Chapters into Documents/Books/<id>/.

import Foundation
import Observation
import SwiftUI

@Observable
final class ServerClient {
    struct Item: Identifiable, Decodable {
        struct Media: Decodable {
            struct Metadata: Decodable {
                var title: String?
                var authorName: String?
            }
            var metadata: Metadata
            var numAudioFiles: Int?
            var duration: Double?
            var size: Int?
        }
        var id: String
        var media: Media
        var title: String { media.metadata.title ?? id }
    }

    var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://"
    var username = UserDefaults.standard.string(forKey: "username") ?? ""
    var password = ""
    private(set) var token: String?
    private(set) var items: [Item] = []
    private(set) var message = ""
    private(set) var downloading: String?
    private(set) var progress = ""

    private var base: URL? { URL(string: serverURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }

    func signIn() async {
        guard let base else { message = "Bad URL"; return }
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        UserDefaults.standard.set(username, forKey: "username")
        message = "Signing in…"
        do {
            var req = URLRequest(url: base.appendingPathComponent("login"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("true", forHTTPHeaderField: "x-return-tokens")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
            let json = try await fetchJSON(req)
            let user = json["user"] as? [String: Any]
            guard let t = (user?["accessToken"] as? String) ?? (user?["token"] as? String) else { message = "No token in response"; return }
            token = t
            password = ""
            let libs = try await fetchJSON(request("api/libraries"))
            let libraries = (libs["libraries"] as? [[String: Any]] ?? []).filter { $0["mediaType"] as? String == "book" }
            guard let libraryID = libraries.first?["id"] as? String else { message = "No book library"; return }
            message = "Loading Library…"
            let (data, _) = try await URLSession.shared.data(for: request("api/libraries/\(libraryID)/items?limit=0&minified=1&sort=media.metadata.title"))
            struct Page: Decodable { var results: [Item] }
            items = try JSONDecoder().decode(Page.self, from: data).results
            message = "\(items.count) Books"
        } catch {
            message = "✖︎ \(error.localizedDescription)"
        }
    }

    func download(_ item: Item) async {
        guard downloading == nil else { return }
        downloading = item.id
        defer { downloading = nil }
        do {
            progress = "fetching details…"
            let json = try await fetchJSON(request("api/items/\(item.id)?expanded=1"))
            guard let media = json["media"] as? [String: Any], let tracks = media["tracks"] as? [[String: Any]] else {
                progress = "✖︎ no tracks"
                return
            }
            let dir = BookStore.downloadsRoot.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var bookTracks: [Book.Track] = []
            for (i, t) in tracks.enumerated() {
                let meta = t["metadata"] as? [String: Any]
                let ext = (meta?["ext"] as? String) ?? ".m4b"
                let name = String(format: "%03d", i + 1) + ext
                let dest = dir.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    guard let path = t["contentUrl"] as? String else { continue }
                    let count = tracks.count
                    let reporter = ProgressReporter { [weak self] written, total in
                        Task { @MainActor in
                            self?.progress = String(format: "file %d/%d: %.0f / %.0f MB", i + 1, count, Double(written) / 1e6, Double(total) / 1e6)
                        }
                    }
                    let (tmp, _) = try await URLSession.shared.download(for: request(String(path.dropFirst())), delegate: reporter)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                }
                bookTracks.append(Book.Track(file: name, startOffset: t["startOffset"] as? Double ?? 0, duration: t["duration"] as? Double ?? 0))
            }
            let chapters = (media["chapters"] as? [[String: Any]] ?? []).map {
                Book.Chapter(title: $0["title"] as? String ?? "", start: $0["start"] as? Double ?? 0, end: $0["end"] as? Double ?? 0)
            }
            let metadata = media["metadata"] as? [String: Any]
            var book = Book(id: item.id, title: item.title, author: metadata?["authorName"] as? String ?? "",
                            duration: media["duration"] as? Double ?? 0, hasToneChannel: false, tracks: bookTracks, chapters: chapters)
            book.directory = dir
            try BookStore.save(book)
            progress = "✔︎ \(item.title)"
        } catch {
            progress = "✖︎ \(error.localizedDescription)"
        }
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(base!.absoluteString)/\(path)")!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func fetchJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

private nonisolated final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    private var last = Date.distantPast

    init(_ onProgress: @escaping @Sendable (Int64, Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard Date.now.timeIntervalSince(last) > 0.3 else { return }
        last = .now
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct ServerView: View {
    @State private var server = ServerClient()
    @State private var query = ""
    @State private var multiFileOnly = false
    var onDownloaded: () -> Void

    var body: some View {
        List {
            if server.token == nil {
                Section("Sign in (password is not stored)") {
                    TextField("Server URL", text: $server.serverURL).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Username", text: $server.username).textInputAutocapitalization(.never)
                    SecureField("Password", text: $server.password)
                    Button("Sign in") { Task { await server.signIn() } }
                }
            } else {
                Section {
                    Toggle("Multi-file Books only", isOn: $multiFileOnly)
                    if !server.progress.isEmpty { Text(server.progress).font(.caption.monospaced()) }
                }
                Section {
                    ForEach(filtered) { item in
                        Button {
                            Task {
                                await server.download(item)
                                onDownloaded()
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text("\(item.media.numAudioFiles ?? 0) file(s) · \(clock(item.media.duration ?? 0)) · \((item.media.size ?? 0) / 1_000_000) MB")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(server.downloading != nil)
                    }
                }
            }
            if !server.message.isEmpty { Text(server.message).font(.caption) }
        }
        .searchable(text: $query)
        .navigationTitle("Download from Server")
    }

    private var filtered: [ServerClient.Item] {
        server.items.filter {
            (!multiFileOnly || ($0.media.numAudioFiles ?? 0) > 1) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }
    }
}
