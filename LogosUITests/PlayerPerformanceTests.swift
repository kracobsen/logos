import XCTest

/// Play, seek and the player sheet, on the fixture's downloaded Books (budgets in `docs/performance-budgets.md`).
/// The signposts end when AVPlayer starts playing or a seek lands; when sound actually comes out of the speaker is a
/// manual check.
@MainActor
final class PlayerPerformanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        Logos.seed("library940")
        app = Logos.app("library940")
        app.launch()
        // The last-played Book is restored, paused.
        XCTAssertTrue(app.miniPlayer.waitForExistence(timeout: 10), "The last-played Book wasn't restored")
    }

    private var pause: XCUIElement { app.buttons["Pause"].firstMatch }

    /// Play, Book already loaded → audio: the mini-player's Play.
    func testPlayLoadedBook() {
        let play = app.buttons["Play"].firstMatch
        measure(metrics: [Logos.budget("PlayLoadedBook")], options: .manual) {
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            startMeasuring()
            play.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 5), "It didn't start playing")
            stopMeasuring()
            pause.tap()
        }
    }

    /// Play, another downloaded Book → audio: In Progress lists the downloaded Books most recent first, so the
    /// second row's Resume is always a Book that isn't loaded.
    func testPlayOtherBook() {
        app.openTab("In Progress")
        let resumes = app.buttons.matching(NSPredicate(format: "label == 'Resume'"))
        measure(metrics: [Logos.budget("PlayOtherBook")], options: .manual) {
            let other = resumes.element(boundBy: 1)
            XCTAssertTrue(other.waitForExistence(timeout: 5), "No second downloaded Book in In Progress")
            startMeasuring()
            other.tap()
            XCTAssertTrue(pause.waitForExistence(timeout: 5), "It didn't start playing")
            stopMeasuring()
            pause.tap()
        }
    }

    /// Seek / skip / Chapter jump → audio: skips in the player sheet, forward then back.
    func testSkipToAudio() {
        app.miniPlayer.tap()
        let forward = app.button(startingWith: "Skip forward")
        let back = app.button(startingWith: "Skip back")
        XCTAssertTrue(forward.waitForExistence(timeout: 5), "The player didn't open")
        var index = 0
        measure(metrics: [Logos.budget("SeekToAudio")], options: .manual) {
            let skip = index % 2 == 0 ? forward : back
            index += 1
            startMeasuring()
            skip.tap()
            Thread.sleep(forTimeInterval: 1)  // the seek lands asynchronously, with no on-screen end
            stopMeasuring()
        }
    }

    /// Player sheet open and scrubbing: hitches while the sheet opens, the scrubber is dragged, and it closes.
    func testPlayerSheetHitches() {
        measure(metrics: [XCTHitchMetric(application: app)], options: .fiveRuns) {
            app.miniPlayer.tap()
            let scrubber = app.sliders["Position in Chapter"]
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "The player didn't open")
            scrubber.adjust(toNormalizedSliderPosition: 0.8)
            scrubber.adjust(toNormalizedSliderPosition: 0.2)
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.miniPlayer.waitForExistence(timeout: 5))
        }
    }
}
