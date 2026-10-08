import Foundation
import Security
import Synchronization

/// The token store seam under ``Auth``: ``KeychainTokenStore`` in the app, ``InMemoryTokenStore`` in tests.
///
/// It holds only the token pair. The password is never stored anywhere.
public protocol TokenStore: Sendable {
    func load() throws -> TokenPair?
    func save(_ tokens: TokenPair) throws
    func clear() throws
}

/// Stores the token pair in the Keychain, readable after first unlock and on this device only (so a backup
/// restored to another device needs one sign-in).
public struct KeychainTokenStore: TokenStore {
    public struct KeychainError: Error, Hashable {
        public let status: OSStatus
    }

    private let service: String
    private let account: String

    public init(service: String = "Logos", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> TokenPair? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(TokenPair.self, from: data)
    }

    public func save(_ tokens: TokenPair) throws {
        let data = try JSONEncoder().encode(tokens)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// A token store in memory, for tests.
public final class InMemoryTokenStore: TokenStore {
    public struct SaveFailed: Error {}

    private struct State {
        var tokens: TokenPair?
        var failSaves = false
    }

    private let state: Mutex<State>

    public init(_ tokens: TokenPair? = nil) {
        state = Mutex(State(tokens: tokens))
    }

    /// When true, ``save(_:)`` throws, as a full or locked Keychain would.
    public var failSaves: Bool {
        get { state.withLock { $0.failSaves } }
        set { state.withLock { $0.failSaves = newValue } }
    }

    public func load() throws -> TokenPair? {
        state.withLock { $0.tokens }
    }

    public func save(_ tokens: TokenPair) throws {
        try state.withLock { state in
            if state.failSaves { throw SaveFailed() }
            state.tokens = tokens
        }
    }

    public func clear() throws {
        state.withLock { $0.tokens = nil }
    }
}
