import XCTest

/// Browsing the 3000-Book fixture Library: scroll hitches (and memory while browsing), tap Book → detail, search
/// keystrokes, sort changes and letter-index jumps (budgets in `docs/performance-budgets.md`).
@MainActor
final class LibraryPerformanceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        Logos.seed("library3000")
        app = Logos.app("library3000")
        app.launch()
    }

    // MARK: Scrolling

    func testScrollLibrary() {
        app.openTab("Library")
        measureScrolling()
    }

    func testScrollInProgress() {
        app.openTab("In Progress")
        measureScrolling()
    }

    func testScrollSeriesTab() {
        app.openTab("Series")
        measureScrolling()
    }

    func testScrollSeriesPage() {
        app.openTab("Series")
        // The Series with the most Books: the fixture's longest are 8, so any near the top will do.
        let series = app.list.buttons.firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 10))
        series.tap()
        measureScrolling()
    }

    /// Fast flings down then back up the list on screen: scroll hitch ratio, plus memory while browsing.
    private func measureScrolling() {
        let list = app.list
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        measure(
            metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTMemoryMetric(application: app)],
            options: .fiveRuns
        ) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }

    // MARK: Library paths

    func testTapBookToDetail() {
        app.openTab("Library")
        let rows = app.list.buttons
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        var index = 0
        measure(metrics: [Logos.budget("TapBookToDetail")], options: .manual) {
            let row = rows.element(boundBy: index % 4)
            index += 1
            startMeasuring()
            row.tap()
            XCTAssertTrue(app.staticTexts["Chapters"].waitForExistence(timeout: 10), "Book detail didn't open")
            stopMeasuring()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testSearchKeystroke() {
        app.openTab("Library")
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) || !search.isHittable {
            app.list.swipeDown()  // the search field is revealed by pulling down
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10), "No search field")
        search.tap()
        var index = 0
        measure(metrics: [Logos.budget("SearchKeystroke")], options: .manual) {
            let letter = ["r", "s", "t", "l", "n"][index % 5]
            index += 1
            startMeasuring()
            search.typeText(letter)
            stopMeasuring()
            search.typeText(XCUIKeyboardKey.delete.rawValue)
        }
    }

    func testSortChange() {
        app.openTab("Library")
        let menu = app.buttons["Sort and filter"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        var index = 0
        measure(metrics: [Logos.budget("SortChange")], options: .manual) {
            // Alternate, so each run changes the sort: Author is the slowest order.
            let sort = index % 2 == 0 ? "Author" : "Title"
            index += 1
            menu.tap()
            let item = app.buttons[sort]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(sort) in the menu")
            startMeasuring()
            item.tap()
            stopMeasuring()
        }
    }

    func testLetterIndexJump() {
        app.openTab("Library")
        let strip = app.list.otherElements["Section index"]
        require(strip, in: app, timeout: 10, "No letter index")
        // Far-apart letters, so every tap jumps by more than a screen.
        let letters = ["M", "Z", "C", "T", "G"]
        var index = 0
        measure(metrics: [Logos.budget("LetterIndexJump")], options: .manual) {
            let letter = sectionIndexPoint(letters[index % letters.count], on: strip)
            index += 1
            startMeasuring()
            letter.tap()
            Thread.sleep(forTimeInterval: 0.5)  // the jump ends on the main queue's next turn, after the tap returns
            stopMeasuring()
        }
    }

    /// Where `letter` sits on the section index strip. The index is one accessibility element listing "#" and A–Z
    /// evenly (the fixture has Books under every letter).
    private func sectionIndexPoint(_ letter: String, on strip: XCUIElement) -> XCUICoordinate {
        let letters = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        let position = Double(letters.firstIndex(of: letter) ?? 0)
        return strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (position + 0.5) / Double(letters.count)))
    }
}
