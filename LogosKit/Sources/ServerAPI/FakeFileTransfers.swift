import Domain
import Foundation
import Synchronization

/// The fake side of ``FileTransfers``: background transfers from a ``FakeServer`` (``FakeServer/transfers``).
///
/// Like the real background session, transfers outlive whoever enqueued them: a new Downloads instance (a relaunch)
/// sees them in ``running()``. Nothing finishes on its own; tests decide when and how:
/// - ``serve(_:bookID:ino:)`` sets a file's bytes; an unknown `ino` gets 404;
/// - ``complete(_:)`` / ``completeAll()`` answer pending transfers as the Server would (401 for an expired or revoked
///   token, the file moved to its destination for 200, or 206 when resuming), going through the Server's
///   ``FakeServer/isReachable`` and ``FakeServer/beforeHandling(_:)`` with a ``FakeServer/Request/file`` request;
/// - ``interrupt(_:receivedBytes:)`` stops one part-way, with resume data;
/// - ``reportProgress(_:receivedBytes:)`` sends a progress event.
///
/// Each of those returns once the event handler has finished with the event.
public final class FakeFileTransfers: FileTransfers {
    private struct State {
        var files: [String: Data] = [:]
        var pending: [FileTransferRequest] = []
        var enqueued: [FileTransferRequest] = []
        var handler: (@Sendable (FileTransferEvent) async -> Void)?
        var held: [FileTransferEvent] = []
        var allowsCellularAccess = false
    }

    private unowned let server: FakeServer
    private let state = Mutex(State())

    init(server: FakeServer) {
        self.server = server
    }

    // MARK: Scripting

    /// Serves `data` as the Book's file with this `ino`.
    public func serve(_ data: Data, bookID: String, ino: String) {
        state.withLock { $0.files[Self.key(bookID, ino)] = data }
    }

    /// Stops serving the Book's file with this `ino` (404 from now on).
    public func stopServing(bookID: String, ino: String) {
        state.withLock { _ = $0.files.removeValue(forKey: Self.key(bookID, ino)) }
    }

    /// What ``setAllowsCellularAccess(_:)`` last set (`false` at first). Set it to stand for a new process.
    public var allowsCellularAccess: Bool {
        get { state.withLock { $0.allowsCellularAccess } }
        set { state.withLock { $0.allowsCellularAccess = newValue } }
    }

    /// Every request ever enqueued, in order.
    public var enqueued: [FileTransferRequest] {
        state.withLock { $0.enqueued }
    }

    /// The transfers in flight, in the order they were enqueued.
    public var pending: [FileTransferRequest] {
        state.withLock { $0.pending }
    }

    /// Answers the pending transfer of `transfer`, if there is one.
    public func complete(_ transfer: FileTransfer) async {
        guard let request = take(transfer) else { return }
        await deliver(await answer(request))
    }

    /// Answers every pending transfer, including ones enqueued meanwhile, until none is left (at most `limit`).
    public func completeAll(limit: Int = 100) async {
        for _ in 0..<limit {
            guard let next = pending.first else { return }
            await complete(next.transfer)
        }
    }

    /// Stops the pending transfer part-way, as a dropped connection does. Its resume data stands for the bytes so far.
    public func interrupt(_ transfer: FileTransfer, receivedBytes: Int64) async {
        guard take(transfer) != nil else { return }
        await deliver(
            .failed(transfer, reason: "The network connection was lost.", resumeData: Self.resumeData(receivedBytes)))
    }

    public func reportProgress(_ transfer: FileTransfer, receivedBytes: Int64) async {
        await deliver(.progress(transfer, receivedBytes: receivedBytes))
    }

    /// The resume data ``interrupt(_:receivedBytes:)`` gives for that many bytes.
    public static func resumeData(_ receivedBytes: Int64) -> Data {
        Data("partial:\(receivedBytes)".utf8)
    }

    // MARK: FileTransfers

    public func setEventHandler(_ handler: @escaping @Sendable (FileTransferEvent) async -> Void) async {
        let held = state.withLock { state in
            state.handler = handler
            defer { state.held = [] }
            return state.held
        }
        for event in held { await handler(event) }
    }

    public func enqueue(_ request: FileTransferRequest) async {
        state.withLock { state in
            state.pending.removeAll { $0.transfer == request.transfer }
            state.pending.append(request)
            state.enqueued.append(request)
        }
    }

    public func running() async -> Set<FileTransfer> {
        Set(pending.map(\.transfer))
    }

    public func cancel(bookID: String) async {
        state.withLock { $0.pending.removeAll { $0.transfer.bookID == bookID } }
    }

    public func setAllowsCellularAccess(_ allowed: Bool) async {
        allowsCellularAccess = allowed
    }

    // MARK: Internals

    private func take(_ transfer: FileTransfer) -> FileTransferRequest? {
        state.withLock { state in
            guard let index = state.pending.firstIndex(where: { $0.transfer == transfer }) else { return nil }
            return state.pending.remove(at: index)
        }
    }

    private func answer(_ request: FileTransferRequest) async -> FileTransferEvent {
        let transfer = request.transfer
        let finished = { (status: Int) in
            FileTransferEvent.finished(transfer, status: status, accessToken: request.accessToken)
        }
        do {
            try await server.receiveFileRequest(request)
        } catch .unreachable(let reason) {
            return .failed(transfer, reason: reason, resumeData: request.resumeData)
        } catch .unauthorized {
            return finished(401)
        } catch .rateLimited {
            return finished(429)
        } catch .unexpectedStatus(let status) {
            return finished(status)
        } catch {
            return finished(500)
        }
        guard server.accepts(accessToken: request.accessToken) else { return finished(401) }
        guard let data = state.withLock({ $0.files[Self.key(transfer.bookID, request.ino)] }) else {
            return finished(404)
        }
        do {
            try FileManager.default.createDirectory(
                at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: request.destination)
        } catch {
            return .failed(transfer, reason: "Couldn't write the file: \(error)", resumeData: nil)
        }
        return finished(request.resumeData == nil ? 200 : 206)
    }

    private func deliver(_ event: FileTransferEvent) async {
        let handler = state.withLock { state in
            if state.handler == nil { state.held.append(event) }
            return state.handler
        }
        await handler?(event)
    }

    private static func key(_ bookID: String, _ ino: String) -> String { "\(bookID)/\(ino)" }
}
