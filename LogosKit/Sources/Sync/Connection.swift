import Domain
import Foundation
import ServerAPI
import Store

/// Whether Logos can talk to its Server, as the listener should hear about it.
public enum ConnectionState: Sendable, Hashable {
    /// Signed in, and the Server's version is fine as far as Logos knows. (Unreachable is not a state.)
    case signedIn
    /// The Server rejected the sign-in. Browsing, playback, existing Downloads and recording go on; sync, sending
    /// and new Downloads pause until the listener signs in again as the same user.
    case needsSignIn
    /// The last sync found a Server older than 2.36: sync, sending and the progress fetch stop until it's upgraded.
    case serverTooOld(found: String)
}

/// The signed-in identity's connection: needs sign-in (from its ``Auth``), Server too old (from the last sync's
/// version check), signing in again, and the token side of signing out.
///
/// One per identity, shared by the sync, the outbox and the progress fetch (``LibrarySync/connection``).
public actor Connection {
    private let database: AppDatabase
    private let auth: Auth
    private var needsSignIn = false
    /// The version the last check found, if it was too old.
    private(set) var tooOldVersion: String?
    private var watchers: [UUID: Watcher] = [:]
    private var following: Task<Void, Never>?

    private struct Watcher {
        let continuation: AsyncStream<ConnectionState>.Continuation
        /// What it was last told, so it hears only changes.
        var last: ConnectionState
    }

    init(database: AppDatabase, auth: Auth) {
        self.database = database
        self.auth = auth
    }

    /// The state now.
    public var state: ConnectionState {
        get async {
            needsSignIn = await auth.needsSignIn
            return known
        }
    }

    /// The state as last heard from `Auth`.
    private var known: ConnectionState {
        if needsSignIn { return .needsSignIn }
        if let tooOldVersion { return .serverTooOld(found: tooOldVersion) }
        return .signedIn
    }

    /// The current state, then each change, until the stream is dropped.
    public func updates() async -> AsyncStream<ConnectionState> {
        needsSignIn = await auth.needsSignIn
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConnectionState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers[id] = Watcher(continuation: continuation, last: known)
        continuation.yield(known)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching(id) }
        }
        if following == nil {
            following = Task { [auth, weak self] in
                for await needsSignIn in await auth.needsSignInUpdates() {
                    await self?.authChanged(needsSignIn)
                }
            }
        }
        return stream
    }

    deinit {
        following?.cancel()
    }

    /// Signs in again as the same Server user: on success the new tokens are saved and used, and needs sign-in ends.
    /// The Library, Downloads and the outbox are untouched; the caller resumes sync, sending and Downloads.
    ///
    /// Refused (with nothing changed) for another Server (``SignInError/differentServer``) or another Server user
    /// (``SignInError/differentUser``, that login revoked).
    public func signInAgain(using signIn: SignIn, address: String, username: String, password: String)
        async throws(SignInError)
    {
        let identity: ServerIdentity?
        do {
            identity = try database.serverIdentity()
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
            throw .couldNotSave
        }
        guard let identity else { throw .couldNotSave }
        let tokens = try await signIn.logInAgain(
            as: identity, address: address, username: username, password: password)
        do {
            try await auth.signedInAgain(with: tokens)
        } catch {
            throw .couldNotSave
        }
    }

    /// The token side of signing out: a best-effort `POST /logout`, then the stored tokens are cleared.
    public func signOut() async {
        await auth.signOut()
    }

    /// Records what the sync's version check found: `nil` when the Server's version is supported.
    func serverVersionChecked(tooOld found: String?) {
        guard found != tooOldVersion else { return }
        tooOldVersion = found
        publish()
    }

    private func authChanged(_ needsSignIn: Bool) {
        self.needsSignIn = needsSignIn
        publish()
    }

    private func publish() {
        let state = known
        for (id, watcher) in watchers where watcher.last != state {
            watchers[id]?.last = state
            watcher.continuation.yield(state)
        }
    }

    private func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }
}
