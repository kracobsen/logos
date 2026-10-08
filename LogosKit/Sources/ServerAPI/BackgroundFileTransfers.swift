import Domain
import Foundation
import Synchronization

/// The real ``FileTransfers``: one `URLSession` download task per file.
///
/// In the app it's a background session with a fixed identifier (``backgroundConfiguration(identifier:)``), so
/// transfers carry on while Logos is suspended or not running; build it at launch, including background launches,
/// so the session reconnects and its events are heard. Each task's description records which file it is and where
/// the file goes, so a relaunch knows its tasks.
///
/// A finished file is moved to its destination inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`, before
/// URLSession deletes it. Events go to the handler one at a time, in order; the system's "background events done"
/// completion is called after the handler has finished with them.
public final class BackgroundFileTransfers: NSObject, FileTransfers, Sendable {
    /// What a task's `taskDescription` holds.
    private struct Description: Codable {
        let bookID: String
        let relPath: String
        /// Relative to the home directory when it's inside it: the app container's path can change between launches.
        let destination: String
    }

    private enum Item: Sendable {
        case event(FileTransferEvent)
        /// Called once the handler has dealt with every event before it.
        case flush(@Sendable () -> Void)
    }

    private struct State {
        var handler: (@Sendable (FileTransferEvent) async -> Void)?
        var consumerStarted = false
        /// Tasks stopped by ``cancel(bookID:)``, or already reported: no more events for them.
        var silenced: Set<Int> = []
        var lastProgress: [Int: Date] = [:]
        var backgroundCompletion: (@Sendable () -> Void)?
        /// Set per request (a background session's own setting can't change); Wi-Fi only until told otherwise.
        var allowsCellularAccess = false
    }

    private let state = Mutex(State())
    private let clock: any Clock
    private let sessionBox = Mutex<URLSession?>(nil)
    private let items: AsyncStream<Item>
    private let continuation: AsyncStream<Item>.Continuation

    /// A background configuration for Downloads: launches the app for events, not discretionary, never on
    /// constrained networks (Low Data Mode), no cookies. Cellular is decided per request
    /// (``setAllowsCellularAccess(_:)``), so the configuration allows it.
    public static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsCellularAccess = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    /// - Parameters:
    ///   - configuration: ``backgroundConfiguration(identifier:)`` in the app; a plain one in tests.
    ///   - clock: paces the progress events.
    public init(configuration: URLSessionConfiguration, clock: any Clock = SystemClock()) {
        self.clock = clock
        (items, continuation) = AsyncStream.makeStream(of: Item.self)
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Logos file transfers"
        sessionBox.withLock { $0 = URLSession(configuration: configuration, delegate: self, delegateQueue: queue) }
    }

    private var session: URLSession {
        sessionBox.withLock { $0! }
    }

    /// The system relaunched (or woke) Logos for this session's events: `completion` is called once they've all been
    /// handled. From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public func handleEventsForBackgroundSession(completion: @escaping @Sendable () -> Void) {
        state.withLock { $0.backgroundCompletion = completion }
        _ = session  // reconnects the session if it isn't yet
    }

    // MARK: FileTransfers

    public func setEventHandler(_ handler: @escaping @Sendable (FileTransferEvent) async -> Void) async {
        let startConsumer = state.withLock { state in
            state.handler = handler
            defer { state.consumerStarted = true }
            return !state.consumerStarted
        }
        guard startConsumer else { return }
        // Lives as long as the process: one consumer, so events reach the handler one at a time, in order.
        Task { [items] in
            for await item in items {
                switch item {
                case .event(let event):
                    let handler = self.state.withLock { $0.handler }
                    await handler?(event)
                case .flush(let done):
                    done()
                }
            }
        }
    }

    public func enqueue(_ request: FileTransferRequest) async {
        let transfer = request.transfer
        for task in await tasks(where: { $0.bookID == transfer.bookID && $0.relPath == transfer.relPath }) {
            silence(task)
            task.cancel()
        }
        let urlRequest = Requests.file(
            ofBook: transfer.bookID, ino: request.ino, on: request.server, accessToken: request.accessToken,
            allowsCellular: state.withLock { $0.allowsCellularAccess })
        let task: URLSessionDownloadTask
        if let resumeData = request.resumeData, let retargeted = ResumeData.retargeting(resumeData, to: urlRequest) {
            task = session.downloadTask(withResumeData: retargeted)
        } else {
            task = session.downloadTask(with: urlRequest)
        }
        let description = Description(
            bookID: transfer.bookID, relPath: transfer.relPath, destination: Self.storable(request.destination))
        task.taskDescription = (try? JSONEncoder().encode(description)).flatMap { String(data: $0, encoding: .utf8) }
        task.resume()
    }

    public func running() async -> Set<FileTransfer> {
        Set(
            await tasks(where: { _ in true }).compactMap { task in
                guard task.state == .running || task.state == .suspended,
                    let description = Self.description(of: task)
                else { return nil }
                return FileTransfer(bookID: description.bookID, relPath: description.relPath)
            })
    }

    public func cancel(bookID: String) async {
        for task in await tasks(where: { $0.bookID == bookID }) {
            silence(task)
            task.cancel()
        }
    }

    public func setAllowsCellularAccess(_ allowed: Bool) async {
        let changed = state.withLock { state in
            defer { state.allowsCellularAccess = allowed }
            return state.allowsCellularAccess != allowed
        }
        guard changed else { return }
        // A task's request can't change: replace each running one, resuming from what it has received.
        for task in await tasks(where: { _ in true }) {
            guard let task = task as? URLSessionDownloadTask, var request = task.originalRequest else { continue }
            let description = task.taskDescription
            silence(task)
            let resumeData = await task.cancelByProducingResumeData()
            request.allowsCellularAccess = allowed
            let replacement: URLSessionDownloadTask
            if let resumeData, let retargeted = ResumeData.retargeting(resumeData, to: request) {
                replacement = session.downloadTask(withResumeData: retargeted)
            } else {
                replacement = session.downloadTask(with: request)
            }
            replacement.taskDescription = description
            replacement.resume()
        }
    }

    // MARK: Internals

    private func tasks(where matches: (Description) -> Bool) async -> [URLSessionTask] {
        await session.allTasks.filter { task in
            guard !isSilenced(task), let description = Self.description(of: task) else { return false }
            return matches(description)
        }
    }

    private func silence(_ task: URLSessionTask) {
        state.withLock { _ = $0.silenced.insert(task.taskIdentifier) }
    }

    private func isSilenced(_ task: URLSessionTask) -> Bool {
        state.withLock { $0.silenced.contains(task.taskIdentifier) }
    }

    private func send(_ event: FileTransferEvent) {
        continuation.yield(.event(event))
    }

    private static func description(of task: URLSessionTask) -> Description? {
        guard let text = task.taskDescription else { return nil }
        return try? JSONDecoder().decode(Description.self, from: Data(text.utf8))
    }

    private static func storable(_ destination: URL) -> String {
        let home = URL(filePath: NSHomeDirectory()).standardizedFileURL.path(percentEncoded: false)
        let path = destination.standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
    }

    private static func destination(from stored: String) -> URL {
        stored.hasPrefix("~/")
            ? URL(filePath: NSHomeDirectory()).appending(path: String(stored.dropFirst(2)))
            : URL(filePath: stored)
    }

    private static func bearer(of task: URLSessionTask) -> String {
        let header = task.originalRequest?.value(forHTTPHeaderField: "Authorization") ?? ""
        return header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
    }
}

extension BackgroundFileTransfers: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard !isSilenced(downloadTask), let description = Self.description(of: downloadTask) else { return }
        silence(downloadTask)  // didCompleteWithError follows; this is the report
        let transfer = FileTransfer(bookID: description.bookID, relPath: description.relPath)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 || status == 206 {
            // URLSession deletes `location` when this returns: move it now.
            let destination = Self.destination(from: description.destination)
            do {
                let manager = FileManager.default
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: location, to: destination)
            } catch {
                log.error("Couldn't move a finished file: \(String(describing: error), privacy: .public)")
                send(
                    .failed(transfer, reason: "Couldn't keep the file: \(error.localizedDescription)", resumeData: nil))
                return
            }
        }
        log.info("A file transfer finished with \(status)")
        send(.finished(transfer, status: status, accessToken: Self.bearer(of: downloadTask)))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !isSilenced(task), let description = Self.description(of: task) else { return }
        silence(task)
        let transfer = FileTransfer(bookID: description.bookID, relPath: description.relPath)
        let nsError = error.map { $0 as NSError }
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let reason = nsError?.localizedDescription ?? "The transfer ended without a file"
        log.info("A file transfer stopped: \(reason, privacy: .public)")
        send(.failed(transfer, reason: reason, resumeData: resumeData))
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let description = Self.description(of: downloadTask) else { return }
        let now = clock.now
        let due = state.withLock { state in
            if let last = state.lastProgress[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 0.5 {
                return false
            }
            state.lastProgress[downloadTask.taskIdentifier] = now
            return true
        }
        guard due else { return }
        send(
            .progress(
                FileTransfer(bookID: description.bookID, relPath: description.relPath),
                receivedBytes: totalBytesWritten))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard
            let completion = state.withLock({ state in
                defer { state.backgroundCompletion = nil }
                return state.backgroundCompletion
            })
        else { return }
        continuation.yield(.flush { DispatchQueue.main.async(execute: completion) })
    }
}
