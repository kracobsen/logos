#if LOGOS_TEST_LAUNCH
    import AVFoundation
    import Domain
    import Foundation
    import ServerAPI
    import Store
    import UIKit

    /// Launches for UI and performance tests, chosen by the launch environment. Compiled only into builds with the
    /// `LOGOS_TEST_LAUNCH` condition (Debug and Performance, see `Config/`), so a Release build has none of this: its
    /// sign-in stays HTTPS-only and it always uses its real data.
    ///
    /// - `LOGOS_TEST_LAUNCH=signedOut`: signed out, with fresh, empty data on every launch and tokens in memory, and
    ///   sign-in allows plain HTTP to a loopback Server (the local Docker Server of `scripts/ui-test.sh`).
    /// - `LOGOS_TEST_LAUNCH=library940` or `library3000` (any `library<count>`): signed in to an offline fake Server
    ///   with a generated ``FixtureLibrary`` of that many Books: Book data, covers, progress and a few downloaded
    ///   Books with real (silent) audio, everything already synced. The data is made on the first such launch and
    ///   kept for later ones, so cold launches measure the app, not the seeding; `LOGOS_TEST_LAUNCH_RESET=1` makes
    ///   it again. Syncs run against the fake Server, which serves the same Library (a sync with no changes).
    ///
    /// Test data lives in its own folder in Application Support, apart from the app's real data.
    enum TestLaunch {
        static let modeKey = "LOGOS_TEST_LAUNCH"
        static let resetKey = "LOGOS_TEST_LAUNCH_RESET"
        /// Bump when the seeded data changes shape, so old seeds are made again.
        static let seedVersion = 1

        static func launchEnvironment(
            _ variables: [String: String] = ProcessInfo.processInfo.environment
        ) throws -> LaunchEnvironment? {
            guard let mode = variables[modeKey], !mode.isEmpty else { return nil }
            let root = try LaunchEnvironment.applicationSupport().appending(path: "TestLaunch")
            if mode == "signedOut" {
                let directory = root.appending(path: "signedOut")
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return LaunchEnvironment(
                    directory: directory, api: AudiobookshelfClient(), tokenStore: InMemoryTokenStore(),
                    allowsPlainHTTPOnLoopback: true)
            }
            if mode.hasPrefix("library"), let count = Int(mode.dropFirst("library".count)), count > 0 {
                let directory = root.appending(path: "\(mode)-v\(seedVersion)")
                return try libraryEnvironment(
                    bookCount: count, directory: directory, reset: variables[resetKey] == "1")
            }
            throw UnknownMode(mode: mode)
        }

        struct UnknownMode: Error {
            let mode: String
        }

        // MARK: The fixture Library

        static let serverAddress = URL(string: "https://fixture.logos.invalid")!

        private static func libraryEnvironment(
            bookCount: Int, directory: URL, reset: Bool
        ) throws -> LaunchEnvironment {
            let marker = directory.appending(path: "seeded")
            if reset || !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try seed(FixtureLibrary(bookCount: bookCount), in: directory)
                try Data().write(to: marker)
            }

            let server = FakeServer(address: serverAddress, clock: SystemClock())
            let tokens = InMemoryTokenStore(server.issueTokens(for: .listener).tokens)
            // The fake Server's Library is made off the main thread, after launch; requests wait for it.
            let prepared = Task.detached(priority: .utility) {
                let library = FixtureLibrary(bookCount: bookCount)
                server.books = library.listedBooks
                server.bookData = library.books
                server.progress = library.progress
            }
            server.beforeHandling { _ in await prepared.value }
            var environment = LaunchEnvironment(directory: directory, api: server, tokenStore: tokens)
            // Signing out wiped the seeded data: the next launch of this mode seeds it again.
            environment.signedOut = { try? FileManager.default.removeItem(at: marker) }
            return environment
        }

        /// Writes the Library into a new database in `directory`, as if it had been synced and the downloaded Books
        /// downloaded, and signs in last (the identity is what makes launch show the Library).
        private static func seed(_ library: FixtureLibrary, in directory: URL) throws {
            let database = try AppDatabase.open(at: directory.appending(path: "Logos.sqlite"))
            let covers = try CoverFiles(directory: directory.appending(path: "Covers"))
            let files = try DownloadFiles(directory: directory.appending(path: "Downloads"))
            let now = Date()

            // Downloaded Books get real audio; their tracks take the files' real sizes.
            let downloaded = Set(library.downloadedBookIDs)
            var books = library.books
            for (index, data) in books.enumerated() where downloaded.contains(data.book.id) {
                let tracks = try data.tracks.map { track in
                    let url = files.url(forBook: data.book.id, relPath: track.relPath)
                    let size = try writeSilence(seconds: track.duration, to: url)
                    return AudioTrack(
                        index: track.index, ino: track.ino, relPath: track.relPath, size: size,
                        duration: track.duration, startOffset: track.startOffset, mimeType: track.mimeType)
                }
                books[index] = BookData(book: data.book, chapters: data.chapters, tracks: tracks, series: data.series)
            }

            _ = try database.applyLibraryList(library.listedBooks, syncedAt: now)
            try database.applyBookData(books)

            let coverImages = coverJPEGs()
            for (index, data) in books.enumerated() {
                if data.book.hasCover {
                    try covers.save(coverImages[index % coverImages.count], forBook: data.book.id)
                }
                try database.setCoverVersion(data.book.updatedAt, forBook: data.book.id)
            }

            for data in books where downloaded.contains(data.book.id) {
                let id = data.book.id
                try database.queueDownload(ofBook: id)
                _ = try database.startNextDownload()
                try database.setDownloadFiles(data.tracks, ofBook: id)
                for var file in try database.downloadFiles(ofBook: id) {
                    file.isVerified = true
                    file.receivedBytes = file.size
                    try database.saveDownloadFile(file)
                }
                try database.finishDownload(ofBook: id, at: now)
            }

            _ = try database.applyFetchedProgress(library.progress)
            try database.saveServerIdentity(
                ServerIdentity(
                    serverURL: serverAddress, userID: FakeServer.Account.listener.id,
                    username: FakeServer.Account.listener.username, libraryID: "library-books",
                    libraryName: "Audiobooks"))
        }

        /// Writes silent mono AAC, returning the file's size.
        private static func writeSilence(seconds: Double, to url: URL) throws -> Int64 {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sampleRate = 22_050.0
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            ]
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings)
                let frames = AVAudioFrameCount(sampleRate)  // one second at a time
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                buffer.frameLength = frames  // zero-filled: silence
                for _ in 0..<Int(seconds) {
                    try file.write(from: buffer)
                }
            }  // the file is finished when it goes out of scope
            let size = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]
            return (size as? NSNumber)?.int64Value ?? 0
        }

        /// A few plain covers in different colours, 600 px square like the Server's.
        private static func coverJPEGs() -> [Data] {
            let colours: [UIColor] = [
                .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemIndigo,
                .systemPurple,
            ]
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format)
            return colours.map { colour in
                renderer.jpegData(withCompressionQuality: 0.8) { context in
                    colour.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
                    UIColor.white.withAlphaComponent(0.3).setFill()
                    context.fill(CGRect(x: 60, y: 380, width: 480, height: 80))
                }
            }
        }
    }
#endif
