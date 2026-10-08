import XCTest

/// Cold launch, return from background, the last-played Book, and the sync and progress apply that launch starts (budgets in
/// `docs/performance-budgets.md`). Measure on the iPhone with the `LogosPerformance` scheme, not in CI.
@MainActor
final class LaunchPerformanceTests: XCTestCase {
    func testColdLaunch940() {
        measureColdLaunch("library940")
    }

    func testColdLaunch3000() {
        measureColdLaunch("library3000")
    }

    /// Cold launch → interactive Library: the system's launch metric (to the first frame, then until the app is
    /// responsive), and the app's own interval to the Library's rows.
    private func measureColdLaunch(_ mode: String) {
        Logos.seed(mode)
        let app = Logos.app(mode)
        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                Logos.budget("ColdLaunchToInteractiveLibrary"),
            ], options: .fiveRuns
        ) {
            app.launch()
        }
    }

    /// Last-played Book ready, after interactive: restored paused just after launch, shown in the mini-player.
    func testLastPlayedBookReady() {
        Logos.seed("library940")
        let app = Logos.app("library940")
        measure(metrics: [Logos.budget("LastPlayedBookReady")], options: .manual) {
            startMeasuring()
            app.launch()
            XCTAssertTrue(app.miniPlayer.waitForExistence(timeout: 10), "The last-played Book wasn't restored")
            stopMeasuring()
            app.terminate()
        }
    }

    /// Return from background → interactive: from the scene leaving the background to the next frame on screen.
    func testReturnFromBackground() {
        Logos.seed("library940")
        let app = Logos.app("library940")
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30))
        measure(metrics: [Logos.budget("ReturnFromBackground")], options: .manual) {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "Logos didn't go to the background")
            startMeasuring()
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Logos didn't come back")
            XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
            stopMeasuring()
        }
        app.terminate()
    }

    func testSyncWithNoChanges940() {
        measureLaunchSync("library940", metrics: ["SyncWithNoChanges"])
    }

    /// Sync with no changes on 3000 Books, and applying the fetched progress (which the same sync does).
    func testSyncWithNoChangesAndApplyProgress3000() {
        measureLaunchSync("library3000", metrics: ["SyncWithNoChanges", "ApplyFetchedProgress"])
    }

    /// The launch sync against the fixture's offline fake Server: everything is already synced, so only the local
    /// part (and no Wi-Fi) is measured. Measure the Wi-Fi part against a real Server by hand (Instruments).
    private func measureLaunchSync(_ mode: String, metrics names: [String]) {
        Logos.seed(mode)
        let app = Logos.app(mode)
        measure(metrics: names.map(Logos.budget), options: .manual) {
            startMeasuring()
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30))
            // The sync starts after the first frame and has no on-screen end; a few seconds is plenty offline.
            Thread.sleep(forTimeInterval: 4)
            stopMeasuring()
            app.terminate()
        }
    }
}
