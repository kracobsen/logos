import Domain
import Foundation
import ServerAPI
import Store

/// Why sign-in stopped. Each is shown in place on the sign-in screen.
public enum SignInError: Error, Sendable, Hashable {
    /// The address isn't a usable URL.
    case invalidAddress
    /// The address names a scheme other than HTTPS.
    case httpsRequired
    /// No answer from an audiobookshelf Server at that address.
    case cantReachServer
    /// The Server is older than 2.36 (or its version can't be read). `found` is the version it reported.
    case serverTooOld(found: String)
    /// The Server doesn't allow username and password sign-in.
    case localSignInNotAllowed
    /// The Server rejected the username or password.
    case wrongCredentials
    /// The Server's sign-in rate limit was hit.
    case tooManyAttempts
    /// The user can't see any book Library on the Server (podcast Libraries don't count).
    case noBookLibrary
    /// The Server answered with an error Logos doesn't expect, with its HTTP status.
    case serverError(Int)
    /// The tokens or the identity couldn't be saved on the device.
    case couldNotSave
    /// Signing in again (needs sign-in) named another Server than the one Logos is signed in to.
    case differentServer
    /// Signing in again (needs sign-in) was as another Server user than the one Logos is signed in as.
    case differentUser
}

/// A book Library the user can pick.
public struct LibraryOption: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A sign-in waiting for the user to pick one of several book Libraries. Holds the new tokens in memory only.
public struct LibraryChoice: Sendable, Hashable {
    /// The book Libraries, in the Server's order.
    public let libraries: [LibraryOption]
    let server: URL
    let user: SignedInUser
}

public enum SignInResult: Sendable, Hashable {
    /// Signed in: the identity and tokens are saved.
    case signedIn(ServerIdentity)
    /// Several book Libraries: call ``SignIn/choose(_:from:)`` with the user's pick.
    case chooseLibrary(LibraryChoice)
}

/// Signs in with a Server address, username and password.
///
/// Steps, in order: `/status` (reachable, version ≥ 2.36, local sign-in allowed), `POST /login` for the token pair,
/// then the Library list with podcast Libraries hidden. One book Library is picked automatically. Signing in ends by
/// saving the tokens to the token store and then the ``ServerIdentity`` to the database; the identity is what makes
/// launch skip sign-in. The password is only ever sent to the Server, never stored.
///
/// Only HTTPS is used, and a bare host gets `https://` added.
public struct SignIn: Sendable {
    private let api: any ServerAPI
    private let tokenStore: any TokenStore
    private let database: AppDatabase
    private let allowsPlainHTTPOnLoopback: Bool

    /// - Parameter allowsPlainHTTPOnLoopback: lets `http://` through for a loopback host. Only for integration
    ///   tests against the local Docker Server; the app never sets it.
    public init(
        api: any ServerAPI,
        tokenStore: any TokenStore,
        database: AppDatabase,
        allowsPlainHTTPOnLoopback: Bool = false
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.database = database
        self.allowsPlainHTTPOnLoopback = allowsPlainHTTPOnLoopback
    }

    public func signIn(address: String, username: String, password: String) async throws(SignInError) -> SignInResult {
        let server = try serverURL(from: address)

        let status: ServerStatus
        do {
            status = try await api.status(of: server)
        } catch {
            log.info("Sign-in: status failed: \(String(describing: error), privacy: .public)")
            throw .cantReachServer
        }
        guard status.isSupported else { throw .serverTooOld(found: status.reportedVersion) }
        guard status.allowsLocalSignIn else { throw .localSignInNotAllowed }

        let user: SignedInUser
        do {
            user = try await api.logIn(to: server, username: username, password: password)
        } catch {
            throw Self.signInError(error, unauthorized: .wrongCredentials)
        }

        let libraries: [ServerLibrary]
        do {
            libraries = try await api.libraries(on: server, accessToken: user.tokens.accessToken)
        } catch {
            await logOut(user, on: server)
            throw Self.signInError(error, unauthorized: .serverError(401))
        }
        let books = libraries.filter { $0.mediaType == .book }.map { LibraryOption(id: $0.id, name: $0.name) }

        let choice = LibraryChoice(libraries: books, server: server, user: user)
        switch books.count {
        case 0:
            await logOut(user, on: server)
            throw .noBookLibrary
        case 1:
            do {
                return .signedIn(try choose(books[0], from: choice))
            } catch {
                await logOut(user, on: server)
                throw error
            }
        default: return .chooseLibrary(choice)
        }
    }

    /// The listener gave up on picking a Library: the pending sign-in is revoked on the Server (best effort).
    public func cancel(_ choice: LibraryChoice) async {
        await logOut(choice.user, on: choice.server)
    }

    /// Signing in again from needs sign-in: the same steps up to login, then a check that it's the same Server and
    /// the same Server user id as `identity`. Saves nothing; returns the new pair. Another user's sign-in is revoked.
    func logInAgain(as identity: ServerIdentity, address: String, username: String, password: String)
        async throws(SignInError) -> TokenPair
    {
        let server = try serverURL(from: address)
        guard Self.isSameServer(server, identity.serverURL) else { throw .differentServer }
        let status: ServerStatus
        do {
            status = try await api.status(of: identity.serverURL)
        } catch {
            log.info("Signing in again: status failed: \(String(describing: error), privacy: .public)")
            throw .cantReachServer
        }
        guard status.isSupported else { throw .serverTooOld(found: status.reportedVersion) }
        guard status.allowsLocalSignIn else { throw .localSignInNotAllowed }
        let user: SignedInUser
        do {
            user = try await api.logIn(to: identity.serverURL, username: username, password: password)
        } catch {
            throw Self.signInError(error, unauthorized: .wrongCredentials)
        }
        guard user.id == identity.userID else {
            log.notice("Signing in again as another user: refused")
            await logOut(user, on: identity.serverURL)
            throw .differentUser
        }
        return user.tokens
    }

    /// Best effort: revokes a login Logos won't keep, so no session is left behind on the Server.
    private func logOut(_ user: SignedInUser, on server: URL) async {
        do {
            try await api.logOut(on: server, refreshToken: user.tokens.refreshToken)
        } catch {
            log.info("Couldn't log out an unused sign-in: \(String(describing: error), privacy: .public)")
        }
    }

    /// Scheme, host (any case), port and path (ignoring a trailing slash) match.
    static func isSameServer(_ one: URL, _ other: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            let scheme = components.scheme?.lowercased() ?? ""
            let port = components.port ?? (scheme == "https" ? 443 : 80)
            return "\(scheme)://\(components.host?.lowercased() ?? ""):\(port)\(path)"
        }
        return key(one) != nil && key(one) == key(other)
    }

    /// Finishes a sign-in with the user's pick: saves the tokens, then the identity.
    public func choose(_ library: LibraryOption, from choice: LibraryChoice) throws(SignInError) -> ServerIdentity {
        let identity = ServerIdentity(
            serverURL: choice.server,
            userID: choice.user.id,
            username: choice.user.username,
            libraryID: library.id,
            libraryName: library.name
        )
        do {
            try tokenStore.save(choice.user.tokens)
            try database.saveServerIdentity(identity)
        } catch {
            log.error("Sign-in: couldn't save: \(String(describing: error), privacy: .public)")
            throw .couldNotSave
        }
        log.notice("Signed in")
        return identity
    }

    // MARK: The address

    /// Tidies what the user typed into the Server's base URL: trims it, adds `https://` to a bare host, drops a
    /// trailing slash, and refuses anything but HTTPS.
    func serverURL(from address: String) throws(SignInError) -> URL {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidAddress }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }

        guard
            var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty,
            components.query == nil, components.fragment == nil, components.user == nil
        else { throw .invalidAddress }

        switch scheme {
        case "https": break
        case "http" where allowsPlainHTTPOnLoopback && Self.isLoopback(host): break
        default: throw .httpsRequired
        }
        components.scheme = scheme
        guard let url = components.url else { throw .invalidAddress }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    private static func signInError(_ error: ServerAPIError, unauthorized: SignInError) -> SignInError {
        log.info("Sign-in failed: \(String(describing: error), privacy: .public)")
        return switch error {
        case .unreachable, .unreadableResponse: .cantReachServer
        case .unauthorized: unauthorized
        case .rateLimited: .tooManyAttempts
        case .unexpectedStatus(let code): .serverError(code)
        }
    }
}
