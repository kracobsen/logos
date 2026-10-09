import Domain
import Observation
import Sync

/// The persistent, non-blocking notice above every tab when sync can't run.
public enum ConnectionBanner: Sendable, Hashable {
    /// The Server rejected the sign-in. Tapping it opens the sign-in sheet.
    case needsSignIn
    /// The Server was downgraded below 2.36: sync stopped; Downloads keep playing.
    case serverTooOld(found: String)

    public var title: String {
        switch self {
        case .needsSignIn: "Sign in again to sync"
        case .serverTooOld(let found): "Server too old: audiobookshelf \(found)"
        }
    }

    public var detail: String {
        switch self {
        case .needsSignIn: "Your Downloads and listening are safe. Listening is sent once you sign in."
        case .serverTooOld:
            "Logos needs 2.36 or later, so syncing has stopped. Your Downloads keep playing."
        }
    }
}

/// Needs sign-in, for a signed-in identity: the banner, and the sign-in sheet with the Server address and username
/// filled in. Signing in again as the same Server user resumes sending, sync and paused Downloads with no data
/// touched; another user or Server is refused in place.
@Observable
public final class SignInAgainModel {
    /// The banner to show, if any.
    public private(set) var banner: ConnectionBanner?
    /// The sheet is showing.
    public var isPresented = false
    public var address: String
    public var username: String
    public var password = ""
    public private(set) var isWorking = false
    public private(set) var error: SignInError?

    private let identity: ServerIdentity
    private let connection: Connection
    private let signIn: SignIn
    private let resume: () async -> Void

    /// - Parameter resume: runs after signing in again: sync, send the outbox, resume Downloads.
    public init(
        identity: ServerIdentity, connection: Connection, signIn: SignIn, resume: @escaping () async -> Void
    ) {
        self.identity = identity
        self.connection = connection
        self.signIn = signIn
        self.resume = resume
        address = identity.serverURL.absoluteString
        username = identity.username
    }

    /// Follows the connection until cancelled.
    public func observe() async {
        for await state in await connection.updates() {
            banner =
                switch state {
                case .signedIn: nil
                case .needsSignIn: .needsSignIn
                case .serverTooOld(let found): .serverTooOld(found: found)
                }
        }
    }

    /// Opens the sheet, filled in with the signed-in Server and username.
    public func open() {
        address = identity.serverURL.absoluteString
        username = identity.username
        password = ""
        error = nil
        isPresented = true
    }

    public var canSubmit: Bool {
        !isWorking && [address, username, password].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func submit() async {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await connection.signInAgain(using: signIn, address: address, username: username, password: password)
        } catch {
            self.error = error
            return
        }
        password = ""
        isPresented = false
        await resume()
    }

    public var errorPlacement: SignInModel.ErrorPlacement? { error.map(SignInModel.placement(for:)) }

    public var errorMessage: String? { error.map(SignInModel.message(for:)) }
}
