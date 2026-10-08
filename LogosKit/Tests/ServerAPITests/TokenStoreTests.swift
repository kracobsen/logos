import Foundation
import ServerAPI
import Testing

@Suite("Token stores")
struct TokenStoreTests {
    static let pair = TokenPair(accessToken: "access-1", refreshToken: "refresh-1")
    static let rotated = TokenPair(accessToken: "access-2", refreshToken: "refresh-2")

    static func roundTrip(_ store: some TokenStore) throws {
        #expect(try store.load() == nil)
        try store.save(pair)
        #expect(try store.load() == pair)
        try store.save(rotated)
        #expect(try store.load() == rotated)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()
    }

    @Test("In memory: saves, replaces and clears the pair")
    func inMemory() throws {
        try Self.roundTrip(InMemoryTokenStore())
    }

    // The Keychain store isn't unit-tested: the unhosted test bundle has no Keychain entitlement
    // (errSecMissingEntitlement). It is exercised by the app (sign in, relaunch, still signed in).
}
