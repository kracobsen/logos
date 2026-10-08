import Domain
import Foundation
import ServerAPI
import Store
import Sync
import Testing
import UI

@Suite("Sign in again (needs sign-in banner and sheet)")
@MainActor
struct SignInAgainModelTests {
    func model(_ app: SignedInApp, resumed: (() -> Void)? = nil) -> SignInAgainModel {
        SignInAgainModel(
            identity: app.identity, connection: app.sync.connection,
            signIn: SignIn(api: app.server, tokenStore: app.tokens, database: app.database),
            resume: { resumed?() })
    }

    func enterNeedsSignIn(_ app: SignedInApp) async {
        app.server.revokeAccessTokens()
        app.server.revokeRefreshTokens()
        _ = await app.sync.sync(.manual)
    }

    func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("No banner while signed in; a rejected refresh shows the persistent \"Sign in again to sync\" banner")
    func banner() async throws {
        let app = try await SignedInApp()
        let model = model(app)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await eventually { model.banner == nil }
        #expect(model.banner == nil)

        await enterNeedsSignIn(app)

        await eventually { model.banner != nil }
        #expect(model.banner == .needsSignIn)
        #expect(model.banner?.title == "Sign in again to sync")
    }

    @Test("A Server below 2.36 shows why sync stopped")
    func serverTooOld() async throws {
        let app = try await SignedInApp()
        let model = model(app)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }

        app.server.version = "2.33.0"
        _ = await app.sync.sync(.manual)

        await eventually { model.banner != nil }
        #expect(model.banner == .serverTooOld(found: "2.33.0"))
        #expect(model.banner?.title.contains("2.33.0") == true)
    }

    @Test("The sheet opens with the Server address and username filled in")
    func prefilled() async throws {
        let app = try await SignedInApp()
        let model = model(app)

        model.open()

        #expect(model.isPresented)
        #expect(model.address == "https://abs.example.com")
        #expect(model.username == "listener")
        #expect(model.password == "")
        #expect(!model.canSubmit)
    }

    @Test("Signing in again as the same user closes the sheet, clears the banner and resumes everything")
    func signInAgain() async throws {
        let app = try await SignedInApp()
        var resumed = false
        let model = model(app) { resumed = true }
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await enterNeedsSignIn(app)
        await eventually { model.banner != nil }

        model.open()
        model.password = "listenerpass"
        await model.submit()

        #expect(model.error == nil)
        #expect(!model.isPresented)
        #expect(model.password == "")
        #expect(resumed)
        await eventually { model.banner == nil }
        #expect(model.banner == nil)
    }

    @Test("Another account is refused in place, and the banner stays")
    func differentUser() async throws {
        let app = try await SignedInApp()
        app.server.accounts.append(.init(id: "user-other", username: "other", password: "otherpass"))
        var resumed = false
        let model = model(app) { resumed = true }
        await enterNeedsSignIn(app)

        model.open()
        model.username = "other"
        model.password = "otherpass"
        await model.submit()

        #expect(model.error == .differentUser)
        #expect(model.errorPlacement == .credentials)
        #expect(model.errorMessage?.contains("sign out") == true)
        #expect(model.isPresented)
        #expect(!resumed)
    }
}
