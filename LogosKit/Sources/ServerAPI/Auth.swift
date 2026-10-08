import Domain
import Foundation

/// Why ``Auth`` couldn't make an authenticated call.
public enum AuthError: Error, Sendable, Hashable {
    /// No tokens, or the Server rejected the refresh token. Only signing in again helps.
    case needsSignIn
    /// The call (or a refresh it needed) failed. Not a sign-in problem; try again at the next trigger.
    case server(ServerAPIError)
    /// The rotated pair couldn't be saved, so it wasn't used.
    case tokenStoreFailed
}

/// Owns the tokens. Every authenticated call gets its access token from here.
///
/// - A 401, or less than 5 minutes left on the access token, triggers one shared refresh that every concurrent
///   caller waits on. A call is retried once after a refresh caused by its 401.
/// - The rotated pair is saved to the token store before any request uses it.
/// - A refresh that fails on the network (or is rate-limited) is tried again at the next trigger, never in a loop.
///   If it was only refreshing ahead of time, the still-valid token is used meanwhile.
/// - A refresh the Server rejects (401) means Needs sign-in: from then on calls fail without reaching the Server.
/// - Lifetimes come from the JWT's `exp`; a token without a readable `exp` is refreshed only on a 401.
public actor Auth {
    /// Refresh ahead of time when less than this is left on the access token.
    public static let refreshMargin: Duration = .seconds(5 * 60)

    private let server: URL
    private let api: any ServerAPI
    private let tokenStore: any TokenStore
    private let clock: any Clock

    private var tokens: TokenPair?
    private var refreshing: Task<TokenPair, any Error>?
    /// True once the Server has rejected the refresh token.
    public private(set) var needsSignIn = false

    public init(server: URL, api: any ServerAPI, tokenStore: any TokenStore, clock: any Clock) {
        self.server = server
        self.api = api
        self.tokenStore = tokenStore
        self.clock = clock
    }

    /// Runs `call` with a valid access token, refreshing first or after a 401 as needed.
    public func authorized<T: Sendable>(
        _ call: @Sendable (String) async throws(ServerAPIError) -> T
    ) async throws(AuthError) -> T {
        let current = try await usableTokens()
        do {
            return try await call(current.accessToken)
        } catch .unauthorized {
            let refreshed = try await refreshed(replacing: current)
            do {
                return try await call(refreshed.accessToken)
            } catch {
                throw .server(error)
            }
        } catch {
            throw .server(error)
        }
    }

    /// The current pair, refreshed first if the access token is close to expiry.
    private func usableTokens() async throws(AuthError) -> TokenPair {
        if needsSignIn { throw .needsSignIn }
        let current = try storedTokens()
        guard let expiry = current.accessTokenExpiry,
            expiry.timeIntervalSince(clock.now) < Self.refreshMargin.timeInterval
        else { return current }
        do {
            return try await refreshed(replacing: current)
        } catch .server(let error) where expiry > clock.now {
            log.info(
                "Refreshing ahead of time failed (\(String(describing: error), privacy: .public)); using the current token"
            )
            return current
        }
    }

    private func storedTokens() throws(AuthError) -> TokenPair {
        if let tokens { return tokens }
        let stored: TokenPair?
        do {
            stored = try tokenStore.load()
        } catch {
            log.error("Couldn't read the tokens: \(String(describing: error), privacy: .public)")
            throw .tokenStoreFailed
        }
        guard let stored else { throw .needsSignIn }
        tokens = stored
        return stored
    }

    /// A pair newer than `stale`: the one another caller already got, the refresh in flight, or a new refresh.
    private func refreshed(replacing stale: TokenPair) async throws(AuthError) -> TokenPair {
        if needsSignIn { throw .needsSignIn }
        if let tokens, tokens != stale { return tokens }
        let task: Task<TokenPair, any Error>
        if let refreshing {
            task = refreshing
        } else {
            task = Task { [server, api, tokenStore] in
                let user = try await api.refresh(on: server, refreshToken: stale.refreshToken)
                do {
                    try tokenStore.save(user.tokens)
                } catch {
                    log.error("Couldn't save the rotated tokens: \(String(describing: error), privacy: .public)")
                    throw AuthError.tokenStoreFailed
                }
                return user.tokens
            }
            refreshing = task
        }
        do {
            let pair = try await task.value
            finish(task, with: pair)
            return pair
        } catch let error as AuthError {
            finish(task, with: nil)
            throw error
        } catch ServerAPIError.unauthorized {
            finish(task, with: nil)
            log.notice("The Server rejected the refresh token: needs sign-in")
            needsSignIn = true
            throw .needsSignIn
        } catch let error as ServerAPIError {
            finish(task, with: nil)
            log.info("Refresh failed: \(String(describing: error), privacy: .public)")
            throw .server(error)
        } catch {
            finish(task, with: nil)
            throw .server(.unreachable(String(describing: error)))
        }
    }

    private func finish(_ task: Task<TokenPair, any Error>, with pair: TokenPair?) {
        guard refreshing == task else { return }
        refreshing = nil
        if let pair { tokens = pair }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
