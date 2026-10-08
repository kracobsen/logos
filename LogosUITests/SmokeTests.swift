import XCTest

/// The one end-to-end check that the app works: sign in to the local Docker Server, browse the Library, open a Book,
/// download it, and play it. Run it with `scripts/ui-test.sh`, which starts and seeds the Server (see
/// `scripts/integration-test.sh` for the fixture Library) and passes its address in.
@MainActor
final class SmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSignInBrowseDownloadAndPlay() throws {
        let environment = ProcessInfo.processInfo.environment
        guard
            let server = environment["LOGOS_IT_SERVER_URL"], let username = environment["LOGOS_IT_USERNAME"],
            let password = environment["LOGOS_IT_PASSWORD"]
        else { throw XCTSkip("Needs the Docker Server: run scripts/ui-test.sh") }
        guard let host = URL(string: server)?.host(), ["127.0.0.1", "localhost", "::1"].contains(host) else {
            return XCTFail("Only a loopback Server may be used, not \(server)")
        }

        let app = Logos.app("signedOut")
        app.launch()

        // Sign in.
        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 30), "No sign-in screen")
        address.tap()
        address.typeText(server)
        let usernameField = app.textFields["Username"]
        usernameField.tap()
        usernameField.typeText(username)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons.matching(NSPredicate(format: "label == 'Sign In'")).element(boundBy: 0).tap()
        dismissSavePasswordPrompt()

        // Browse: the Library fills from the Server, sorted by title.
        app.openTab("Library")
        let book = app.list.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The First Light'")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 60), "The Library didn't fill in")
        XCTAssertTrue(
            app.list.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Second Dawn'")).firstMatch.exists)
        book.tap()

        // Open the Book, download it.
        XCTAssertTrue(app.staticTexts["Chapters"].waitForExistence(timeout: 30), "Book detail didn't open")
        // In the Book's list, not the Downloaded tab.
        let download = app.list.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 30), "No Download button")
        download.tap()
        let play = app.buttons["Play"].firstMatch
        require(play, in: app, timeout: 120, "The Download didn't finish")

        // Play it: the button turns to Pause, and the position moves on.
        play.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 30), "It didn't start playing")
        XCTAssertTrue(app.miniPlayer.waitForExistence(timeout: 10), "No mini-player")
        app.miniPlayer.tap()
        let position = app.sliders["Position in Chapter"]
        XCTAssertTrue(position.waitForExistence(timeout: 10), "The player didn't open")
        let started = position.value as? String
        let moved = expectation(
            for: NSPredicate { element, _ in (element as? XCUIElement)?.value as? String != started },
            evaluatedWith: position)
        wait(for: [moved], timeout: 15)
    }

    /// The Passwords app may offer to save the password after signing in.
    private func dismissSavePasswordPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = springboard.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
    }
}
