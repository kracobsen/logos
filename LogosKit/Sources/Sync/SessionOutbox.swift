import Domain
import Foundation
import ServerAPI
import Store

/// How sending the outbox ended.
public enum OutboxSendOutcome: Sendable, Hashable {
    /// The Server answered. `delivered` sessions were confirmed; `rejected` ones failed on their own (their Books
    /// are skipped until the next catalogue sync).
    case sent(delivered: Int, rejected: Int)
    /// Nothing unsent (or everything unsent is held).
    case nothingToSend
    /// Signed out.
    case notNeeded
    case unreachable
    case needsSignIn
    /// The Server answered with an error or something unreadable. Nothing was confirmed.
    case failed
}

/// Sends the listening-sessions outbox to the Server (`POST /api/session/local-all`) and confirms what it accepted.
///
/// The outbox lives in the Store; Playback fills it with every position write. This actor sends the unsent
/// sessions' latest states in one batch, then:
/// - deletes nothing itself: the Store confirms each session the Server accepted, at the revision sent (a closed
///   one then leaves the outbox), and keeps everything else for the next trigger;
/// - skips a Book whose session the Server rejected until the next catalogue sync, so one Book never blocks others;
/// - runs a progress fetch after each send the Server answered.
///
/// Sending never throws and never retries on its own: failures are quiet, and the next trigger (60 s while playing,
/// pause, background, launch, foreground, network return) tries again, with no backoff. A send asked for while one
/// runs makes it go round once more, so the latest state always goes out.
public actor SessionOutbox {
    /// How often the outbox is sent while a Book plays.
    public static let sendInterval: Duration = .seconds(60)
    /// The most sessions in one request.
    public static let batchSize = 100

    private let database: AppDatabase
    private let api: any ServerAPI
    private let auth: Auth
    private let clock: any Clock
    private let progress: ProgressSync
    private var running: Task<OutboxSendOutcome, Never>?
    private var sendsAgain = false
    /// Books whose sessions the Server rejected, with the catalogue sync time they were rejected at.
    private var rejectedBooks: [String: Date?] = [:]

    public init(database: AppDatabase, api: any ServerAPI, auth: Auth, clock: any Clock, progress: ProgressSync) {
        self.database = database
        self.api = api
        self.auth = auth
        self.clock = clock
        self.progress = progress
    }

    /// Sends the unsent sessions, or makes the send already running go round once more.
    @discardableResult
    public func send() async -> OutboxSendOutcome {
        if let running {
            sendsAgain = true
            return await running.value
        }
        let task = Task { await drain() }
        running = task
        let outcome = await task.value
        running = nil
        return outcome
    }

    /// Sends every ``sendInterval`` while a Book plays, until cancelled.
    public func sendWhilePlaying() async {
        for await _ in clock.timer(every: Self.sendInterval) {
            do {
                guard try database.isListening() else { continue }
            } catch {
                log.error("Couldn't read the outbox: \(String(describing: error), privacy: .public)")
                continue
            }
            await send()
        }
    }

    private func drain() async -> OutboxSendOutcome {
        var outcome: OutboxSendOutcome
        repeat {
            sendsAgain = false
            outcome = await run()
            log.info("Outbox send: \(String(describing: outcome), privacy: .public)")
        } while sendsAgain
        return outcome
    }

    private func run() async -> OutboxSendOutcome {
        let identity: ServerIdentity
        var entries: [OutboxSession]
        let device: ClientDevice
        do {
            guard let signedIn = try database.serverIdentity() else { return .notNeeded }
            identity = signedIn
            try database.closeListeningSessionsPausedTooLong(at: clock.now)
            let lastSync = try database.lastLibrarySync()
            rejectedBooks = rejectedBooks.filter { $0.value == lastSync }
            entries = try database.unsentListeningSessions().filter { !rejectedBooks.keys.contains($0.session.bookID) }
            device = try Self.device(database.clientDeviceID())
        } catch {
            log.error("Couldn't read the outbox: \(String(describing: error), privacy: .public)")
            return .failed
        }
        guard !entries.isEmpty else { return .nothingToSend }
        var delivered = 0
        var rejected = 0
        while !entries.isEmpty {
            let batch = Array(entries.prefix(Self.batchSize))
            entries.removeFirst(batch.count)
            let results: [SessionResult]
            do {
                let api = api
                results = try await auth.authorized { token throws(ServerAPIError) in
                    try await api.syncSessions(
                        batch, device: device, libraryID: identity.libraryID, on: identity.serverURL,
                        accessToken: token)
                }
            } catch .needsSignIn {
                return .needsSignIn
            } catch .server(.unreachable) {
                return .unreachable
            } catch {
                log.info("Sending the outbox failed: \(String(describing: error), privacy: .public)")
                return .failed
            }
            let counts = confirm(batch, results)
            delivered += counts.delivered
            rejected += counts.rejected
        }
        _ = await progress.fetch()
        return .sent(delivered: delivered, rejected: rejected)
    }

    /// Confirms the delivered sessions in the Store and remembers the rejected Books.
    private func confirm(_ batch: [OutboxSession], _ results: [SessionResult]) -> (delivered: Int, rejected: Int) {
        let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var confirmed: [(id: UUID, revision: Int)] = []
        var rejected = 0
        let lastSync = try? database.lastLibrarySync()
        for entry in batch {
            guard let result = byID[entry.session.serverID] else { continue }
            if result.isDelivered {
                confirmed.append((entry.session.id, entry.revision))
            } else {
                rejected += 1
                rejectedBooks[entry.session.bookID] = lastSync
                log.notice("The Server rejected a session: \(result.error ?? "no reason", privacy: .public)")
            }
        }
        do {
            try database.confirmListeningSessions(confirmed)
        } catch {
            log.error("Couldn't confirm sent sessions: \(String(describing: error), privacy: .public)")
            return (0, rejected)
        }
        return (confirmed.count, rejected)
    }

    private static func device(_ deviceID: String) -> ClientDevice {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return ClientDevice(
            deviceID: deviceID, clientVersion: version, model: model,
            sdkVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}
