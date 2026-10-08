import Domain
import Foundation
import ServerAPI
import Store

/// Downloads whole Books: every track file plus the cover, one Book at a time, first in, first out.
///
/// The queue lives in the database (ADR 0001), so it survives a force-quit, a crash or a reboot; ``resume()`` rebuilds
/// the transfers from it. The files go through one background session (``FileTransfers``), one transfer per file, all
/// enqueued from the foreground when a Book becomes active. A Book is downloaded only when every file is verified:
/// status 200 or 206 and the size on disk equal to the Server's `metadata.size`.
///
/// - Before a Book's files are enqueued, the token is refreshed if less than ``tokenValidity`` is left, and the
///   Book's full data is fetched again, because a file's `ino` can change (files are keyed by `relPath`). The same
///   happens before any file is enqueued again.
/// - A 401 goes through the shared refresh and enqueues only that file again, from its partial data, without counting
///   as an attempt.
/// - A file of the wrong size is deleted and fetched once more from scratch; a second mismatch fails the Book.
/// - A 403 fails the Book at once. A 404 re-reads the Book and retries the file once (with its fresh `ino`, or not
///   at all if the Book no longer lists it); a second 404 fails the Book.
/// - Any other failure (no response, a timeout, 429, 5xx) counts an attempt and enqueues the file again from its
///   partial data after a ``backoff`` of about 1, 5, then 30 minutes; after ``maxAttempts`` the Book fails. Failed
///   Books keep their verified files, and the queue moves on.
/// - Before a Book becomes active, the volume must have room for its missing files plus ``storageMargin``; if not,
///   the queue pauses as "Not enough storage" until a later ``resume()`` finds room. A transfer that stops while the
///   disk can't hold the rest pauses the queue the same way, without counting an attempt.
/// - Transfers are Wi-Fi only unless ``setAllowsCellular(_:)`` allows cellular (the setting is in the database).
///
/// Never throws: failures are logged, and the database says where each Book is.
public actor Downloader {
    /// Before a Book's files are enqueued, the token is refreshed if less than this is left on it.
    public static let tokenValidity: Duration = .seconds(10 * 60)
    /// Failed tries of one file (401s and size mismatches aside) before its Book fails.
    public static let maxAttempts = 5
    /// How long to wait before trying a file again after its 1st, 2nd, 3rd (and later) failed try.
    public static let backoff: [Duration] = [.seconds(60), .seconds(5 * 60), .seconds(30 * 60)]
    /// Before a Book becomes active, the volume must have room for the bytes it still needs plus this much.
    public static let storageMargin: Int64 = 500_000_000
    /// Progress is written to the database at most this often per file.
    static let progressInterval: TimeInterval = 1

    let database: AppDatabase
    private let api: any ServerAPI
    private let auth: Auth
    private let transfers: any FileTransfers
    let files: DownloadFiles
    let covers: CoverFiles?
    private let clock: any Clock
    private let storage: any StorageCapacity
    private var isInForeground: Bool
    private var isStarted = false
    private var lastProgressWrite: [FileTransfer: Date] = [:]
    /// Files waiting out their backoff before they're enqueued again (in memory: a relaunch retries at once).
    private var backingOff: [FileTransfer: Task<Void, Never>] = [:]
    /// Files that got a 404 and were retried once with a re-read Book (in memory, like ``backingOff``).
    private var retriedAfterNotFound: Set<FileTransfer> = []

    /// - Parameters:
    ///   - covers: where the cover cache keeps covers; a Download shares its Book's cover file with it.
    ///   - inForeground: `false` when built for a background launch: transfer events are handled, but no new Book
    ///     starts until ``resume()``.
    ///   - storage: the free-space check; by default, the volume of `files`.
    public init(
        database: AppDatabase,
        api: any ServerAPI,
        auth: Auth,
        transfers: any FileTransfers,
        files: DownloadFiles,
        covers: CoverFiles?,
        clock: any Clock,
        inForeground: Bool = true,
        storage: (any StorageCapacity)? = nil
    ) {
        self.database = database
        self.api = api
        self.auth = auth
        self.transfers = transfers
        self.files = files
        self.covers = covers
        self.clock = clock
        self.storage = storage ?? VolumeStorageCapacity(volumeOf: files.directory)
        isInForeground = inForeground
    }

    /// Starts handling transfer events, including ones that arrived before this launch was ready. Call it as early as
    /// possible, also when Logos is launched in the background to hear about finished transfers.
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        await transfers.setAllowsCellularAccess(policy.allowsCellular)
        await transfers.setEventHandler { [weak self] event in
            await self?.handle(event)
        }
    }

    /// The "Allow downloads over cellular" setting: saved, and applied to the transfers, running ones included.
    public func setAllowsCellular(_ allowed: Bool) async {
        do {
            try database.setAllowsCellularDownloads(allowed)
        } catch {
            log.error("Couldn't save the cellular setting: \(String(describing: error), privacy: .public)")
        }
        await transfers.setAllowsCellularAccess(allowed)
    }

    /// From the foreground (launch, return, or a tap): rebuilds the active Book's transfers from the database and
    /// starts the next Books.
    public func resume() async {
        await start()
        isInForeground = true
        await advance()
    }

    /// Logos went to the background: transfers carry on, but no new Book starts until ``resume()``.
    public func enteredBackground() {
        isInForeground = false
    }

    /// Puts the Book at the end of the queue (again, if it failed) and starts it if nothing else is downloading.
    public func download(_ bookID: String) async {
        do {
            try database.queueDownload(ofBook: bookID)
        } catch {
            log.error("Couldn't queue a Download: \(String(describing: error), privacy: .public)")
            return
        }
        await resume()
    }

    /// Stops (or removes) the Book's Download and deletes its files straight away, partial ones included. Progress
    /// and the Book's place in the Library are kept, except for a Not on Server Book: it's deleted entirely, cover
    /// included. The next Book starts.
    public func cancel(_ bookID: String) async {
        stopBackoff(ofBook: bookID)
        await transfers.cancel(bookID: bookID)
        do {
            if try database.discardDownload(ofBook: bookID) {
                covers?.delete(forBook: bookID)
            }
        } catch {
            log.error("Couldn't remove a Download: \(String(describing: error), privacy: .public)")
        }
        files.deleteBook(bookID)
        await advance()
    }

    // MARK: The queue

    /// Starts Books until one is in flight or the queue is empty. Only in the foreground.
    private func advance() async {
        guard isInForeground else { return }
        while true {
            guard checkStorage() else { return }
            let bookID: String?
            do {
                bookID = try database.startNextDownload()
            } catch {
                log.error("Couldn't read the Download queue: \(String(describing: error), privacy: .public)")
                return
            }
            guard let bookID else { return }
            switch await transferMissingFiles(of: bookID) {
            case .inFlight, .waiting:
                return
            case .done, .failed, .gone:
                continue
            }
        }
    }

    private enum Progress {
        /// Some files are being transferred.
        case inFlight
        /// Every file is verified: the Book is downloaded now.
        case done
        /// The Book failed now.
        case failed
        /// Couldn't start (offline, needs sign-in): the next ``resume()`` tries again.
        case waiting
        /// The Download was cancelled meanwhile.
        case gone
    }

    /// Before a Book becomes active (or the active one carries on after a storage pause), the volume must have room
    /// for what it still needs plus ``storageMargin``. Pauses the queue as "Not enough storage" if not, and lifts the
    /// pause once there's room (or nothing left to start).
    private func checkStorage() -> Bool {
        let fits: Bool
        let paused: Bool
        do {
            paused = try database.downloadPolicy().isPausedForStorage
            let candidate = try database.nextDownloadToStart() ?? (paused ? database.activeDownload() : nil)
            fits = try candidate.map { try hasRoom(for: $0, margin: Self.storageMargin) } ?? true
        } catch {
            log.error("Couldn't check the free space: \(String(describing: error), privacy: .public)")
            return false
        }
        if fits == paused { setPausedForStorage(!fits) }
        return fits
    }

    private func hasRoom(for bookID: String, margin: Int64) throws -> Bool {
        guard let available = storage.availableForImportantUsage() else { return true }
        return try database.bytesStillNeeded(forBook: bookID) + margin <= available
    }

    private func setPausedForStorage(_ paused: Bool) {
        if paused { log.notice("Not enough storage: the Download queue is paused") }
        do {
            try database.setDownloadsPausedForStorage(paused)
        } catch {
            log.error("Couldn't record the storage pause: \(String(describing: error), privacy: .public)")
        }
    }

    private var isPausedForStorage: Bool { policy.isPausedForStorage }

    private var policy: DownloadPolicy {
        do {
            return try database.downloadPolicy()
        } catch {
            log.error("Couldn't read the Download policy: \(String(describing: error), privacy: .public)")
            return .default
        }
    }

    /// Enqueues every file of the active Book that isn't verified or in flight, after making the token fresh and
    /// reading the Book's files again. Finishes the Book if nothing is left.
    private func transferMissingFiles(of bookID: String) async -> Progress {
        guard !isPausedForStorage else { return .waiting }
        guard let server = signedInServer() else { return .waiting }
        let token: String
        let data: BookData
        do {
            token = try await auth.accessToken(validFor: Self.tokenValidity)
            data = try await auth.authorized { [api] token throws(ServerAPIError) in
                try await api.bookData(for: bookID, on: server, accessToken: token)
            }
        } catch .server(.unexpectedStatus(let status)) where status == 404 || status == 403 {
            log.notice("A Download's Book is gone from the Server (\(status)); failing it")
            return fail(bookID)
        } catch {
            log.info("Couldn't start a Download: \(String(describing: error), privacy: .public)")
            return .waiting
        }
        guard !data.tracks.isEmpty else {
            log.notice("A Download's Book has no audio files; failing it")
            return fail(bookID)
        }
        if case .waiting = await fetchCoverIfNeeded(data.book, server: server) { return .waiting }
        do {
            try database.applyBookData([data])
            try database.setDownloadFiles(data.tracks, ofBook: bookID)
        } catch {
            log.error("Couldn't record a Download's files: \(String(describing: error), privacy: .public)")
            return .waiting
        }
        let running = await transfers.running()
        guard isDownloading(bookID), var known = try? database.downloadFiles(ofBook: bookID) else { return .gone }
        for index in known.indices where !known[index].isVerified {
            let file = known[index]
            let transfer = FileTransfer(bookID: bookID, relPath: file.relPath)
            if running.contains(transfer) || backingOff[transfer] != nil { continue }
            // Arrived just before Logos was killed, before it could be recorded.
            if file.resumeData == nil, files.size(ofBook: bookID, relPath: file.relPath) == file.size {
                known[index].isVerified = true
                known[index].receivedBytes = file.size
                save(known[index])
                continue
            }
            guard let track = data.tracks.first(where: { $0.relPath == file.relPath }) else { continue }
            await transfers.enqueue(
                FileTransferRequest(
                    transfer: transfer, ino: track.ino, server: server, accessToken: token,
                    destination: files.url(forBook: bookID, relPath: file.relPath), resumeData: file.resumeData))
        }
        return finishIfComplete(bookID) ? .done : .inFlight
    }

    /// The cover is part of the Download and shares the cover cache's file. A Book without a cover (or a 404) needs
    /// none; other failures leave it to the cover sync.
    private func fetchCoverIfNeeded(_ book: ListedBook, server: URL) async -> Progress? {
        guard let covers, book.hasCover, !covers.exists(forBook: book.id) else { return nil }
        do {
            let cover = try await auth.authorized { [api] token throws(ServerAPIError) in
                try await api.cover(ofBook: book.id, on: server, accessToken: token)
            }
            try covers.save(cover, forBook: book.id)
            try database.setCoverVersion(book.updatedAt, forBook: book.id)
        } catch AuthError.server(.unreachable), AuthError.needsSignIn {
            return .waiting
        } catch {
            log.info("Couldn't fetch a Download's cover: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    private func finishIfComplete(_ bookID: String) -> Bool {
        guard let known = try? database.downloadFiles(ofBook: bookID), !known.isEmpty,
            known.allSatisfy(\.isVerified), isDownloading(bookID)
        else { return false }
        do {
            try database.finishDownload(ofBook: bookID, at: clock.now)
            log.info("A Book is downloaded")
            return true
        } catch {
            log.error("Couldn't finish a Download: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func fail(_ bookID: String) -> Progress {
        do {
            try database.failDownload(ofBook: bookID)
        } catch {
            log.error("Couldn't fail a Download: \(String(describing: error), privacy: .public)")
        }
        return .failed
    }

    // MARK: Events

    private func handle(_ event: FileTransferEvent) async {
        switch event {
        case .progress(let transfer, let received):
            recordProgress(transfer, received: received)
        case .finished(let transfer, let status, let token):
            await finished(transfer, status: status, token: token)
        case .failed(let transfer, let reason, let resumeData):
            log.info("A file transfer stopped: \(reason, privacy: .public)")
            guard var file = activeFile(transfer) else { return }
            file.resumeData = resumeData
            if (try? hasRoom(for: transfer.bookID, margin: 0)) == false {
                // Not a network failure: wait for space instead of using up attempts.
                save(file)
                setPausedForStorage(true)
                return
            }
            await retry(file)
        }
    }

    private func finished(_ transfer: FileTransfer, status: Int, token: String) async {
        guard var file = activeFile(transfer) else {
            // Cancelled or failed meanwhile: don't keep what arrived.
            if (try? database.downloadStatus(ofBook: transfer.bookID)) == nil {
                files.delete(bookID: transfer.bookID, relPath: transfer.relPath)
            }
            return
        }
        switch status {
        case 200, 206:
            if files.size(ofBook: transfer.bookID, relPath: transfer.relPath) == file.size {
                file.isVerified = true
                file.receivedBytes = file.size
                file.resumeData = nil
                save(file)
                if finishIfComplete(transfer.bookID) { await advance() }
                return
            }
            log.notice("A file arrived with the wrong size; deleting it")
            files.delete(bookID: transfer.bookID, relPath: transfer.relPath)
            file.sizeMismatches += 1
            file.receivedBytes = 0
            file.resumeData = nil
            save(file)
            if file.sizeMismatches >= 2 {
                await failActive(transfer.bookID)
            } else {
                await continueActive(transfer.bookID)
            }
        case 401:
            do {
                _ = try await auth.accessToken(replacingRejected: token)
            } catch {
                log.info("Couldn't refresh for a Download: \(String(describing: error), privacy: .public)")
                return
            }
            await continueActive(transfer.bookID)
        case 403:
            log.notice("A file transfer was forbidden (403); failing its Book")
            await failActive(transfer.bookID)
        case 404 where !retriedAfterNotFound.contains(transfer):
            // The ino may have changed: re-reading the Book gives the fresh one (or drops a file it no longer lists).
            log.notice("A file transfer got 404; re-reading the Book and retrying once")
            retriedAfterNotFound.insert(transfer)
            await continueActive(transfer.bookID)
        case 404:
            log.notice("A file transfer got 404 again; failing its Book")
            await failActive(transfer.bookID)
        default:
            log.info("A file transfer got status \(status)")
            await retry(file)
        }
    }

    /// Counts a failed try and enqueues the file again (from its partial data) after its ``backoff``, or fails the
    /// Book after too many.
    private func retry(_ file: DownloadFile) async {
        var file = file
        file.attempts += 1
        save(file)
        if file.attempts >= Self.maxAttempts {
            await failActive(file.bookID)
            return
        }
        let transfer = FileTransfer(bookID: file.bookID, relPath: file.relPath)
        let delay = Self.backoff[min(file.attempts, Self.backoff.count) - 1]
        backingOff[transfer]?.cancel()
        // From now, not from when the task gets to run.
        let due = clock.now.addingTimeInterval(TimeInterval(delay.components.seconds))
        backingOff[transfer] = Task { [clock, weak self] in
            do {
                try await clock.sleep(for: .seconds(due.timeIntervalSince(clock.now)))
            } catch {
                return
            }
            await self?.backoffEnded(transfer)
        }
    }

    private func backoffEnded(_ transfer: FileTransfer) async {
        backingOff[transfer] = nil
        await continueActive(transfer.bookID)
    }

    private func stopBackoff(ofBook bookID: String) {
        retriedAfterNotFound = retriedAfterNotFound.filter { $0.bookID != bookID }
        for (transfer, task) in backingOff where transfer.bookID == bookID {
            task.cancel()
            backingOff[transfer] = nil
        }
    }

    private func continueActive(_ bookID: String) async {
        switch await transferMissingFiles(of: bookID) {
        case .done, .failed: await advance()
        case .inFlight, .waiting, .gone: break
        }
    }

    private func failActive(_ bookID: String) async {
        stopBackoff(ofBook: bookID)
        await transfers.cancel(bookID: bookID)
        _ = fail(bookID)
        await advance()
    }

    private func recordProgress(_ transfer: FileTransfer, received: Int64) {
        let now = clock.now
        if let last = lastProgressWrite[transfer], now.timeIntervalSince(last) < Self.progressInterval { return }
        guard var file = activeFile(transfer) else { return }
        lastProgressWrite[transfer] = now
        file.receivedBytes = received
        save(file)
    }

    // MARK: Helpers

    /// The file, if its Book is the one downloading and the file isn't verified yet.
    private func activeFile(_ transfer: FileTransfer) -> DownloadFile? {
        guard isDownloading(transfer.bookID),
            let file = try? database.downloadFiles(ofBook: transfer.bookID).first(where: {
                $0.relPath == transfer.relPath
            }),
            !file.isVerified
        else { return nil }
        return file
    }

    private func isDownloading(_ bookID: String) -> Bool {
        (try? database.downloadStatus(ofBook: bookID))?.state == .downloading
    }

    private func save(_ file: DownloadFile) {
        do {
            try database.saveDownloadFile(file)
        } catch {
            log.error("Couldn't save a Download file's state: \(String(describing: error), privacy: .public)")
        }
    }

    private func signedInServer() -> URL? {
        do {
            return try database.serverIdentity()?.serverURL
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
