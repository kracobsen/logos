import XCTest

/// Launching the app for UI tests, and finding things in it by what the listener sees (labels, tab names), so the
/// tests survive layout changes.
@MainActor
enum Logos {
    /// A launch of the app in a `TestLaunch` mode (see `Logos/TestLaunch.swift`): `"signedOut"`, `"library940"` or
    /// `"library3000"`.
    static func app(_ mode: String, reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOGOS_TEST_LAUNCH"] = mode
        if reset { app.launchEnvironment["LOGOS_TEST_LAUNCH_RESET"] = "1" }
        return app
    }

    private static var seeded: Set<String> = []

    /// Makes the fixture Library's data once per test run (a launch that seeds it, then quits), so measured launches
    /// find it ready. Seeding 3000 Books takes a while on first launch.
    static func seed(_ mode: String) {
        guard !seeded.contains(mode) else { return }
        let app = app(mode, reset: true)
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 300), "\(mode) didn't open signed in")
        app.terminate()
        seeded.insert(mode)
    }

    /// A signpost interval on a budgeted path (`BudgetedPath` in Domain): subsystem `Logos`, category `Budgets`.
    static func budget(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "Logos", category: "Budgets", name: name)
    }
}

extension XCUIApplication {
    /// Opens a tab by its title ("In Progress", "Library", "Series", "Downloaded").
    func openTab(_ title: String) {
        let tab = tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "No \(title) tab")
        // A tap while the shell is still appearing (just after sign-in) can be lost: tap until it's selected.
        for _ in 0..<5 where !tab.isSelected {
            tab.tap()
            _ = tab.wait(for: \.isSelected, toEqual: true, timeout: 2)
        }
        XCTAssertTrue(tab.isSelected, "Couldn't open the \(title) tab")
    }

    /// The first list on screen (SwiftUI lists are collection views).
    var list: XCUIElement { collectionViews.firstMatch }

    /// The mini-player (its open button), once a Book is loaded.
    var miniPlayer: XCUIElement { buttons["miniPlayer"] }

    /// A button whose label starts with `prefix`, e.g. "Download" for "Download · 1.2 MB".
    func button(startingWith prefix: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
}

extension XCTestCase {
    /// Waits for `element`; if it doesn't come, fails with `message` and attaches what was on screen.
    @MainActor
    func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval, _ message: String) {
        guard !element.waitForExistence(timeout: timeout) else { return }
        let screen = XCTAttachment(string: app.debugDescription)
        screen.name = "What was on screen"
        screen.lifetime = .keepAlways
        add(screen)
        XCTFail(message)
    }
}

extension XCTMeasureOptions {
    /// Five runs, the median and worst of which the budgets compare against, started and stopped by the test so
    /// setup and clean-up in each run aren't measured.
    static var manual: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    /// Five runs, the whole block measured.
    static var fiveRuns: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        return options
    }
}
