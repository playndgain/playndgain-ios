import XCTest

/// End-to-end against a local wall at http://localhost:8765 (see TESTING.md).
/// Each test launches the Example with launch arguments, drives the real SDK
/// screens and attaches a screenshot.
final class WallUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ user: String, lang: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-base", "http://localhost:8765", "-userid", user, "-lang", lang, "-autoshow", "1"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func log(_ app: XCUIApplication) -> String {
        app.textViews.firstMatch.value as? String ?? ""
    }

    func testOffersDetailClickReturnAndHistory() {
        let app = launch("IOS_FLOW")
        // A card is one accessibility element labelled "name, reward currency".
        // The wall's test offer: in test mode its click lands on the wall's own
        // page instead of an advertiser, the same on every machine.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 15))
        shot("01-offers")

        // Search for it: it can also sit in the featured rail, scrolled out of
        // view, and a search hides the rail.
        let search = app.searchFields.firstMatch
        search.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { search.tap() }
        search.typeText("Test Offer\n")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Test Offer,'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let start = app.buttons["Start this offer"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["What you have to do"].exists)
        shot("02-detail")

        start.tap()
        // The click resolves inside the app. A web landing (a test-mode click
        // lands on the wall's own notice page) rises as the browser sheet. A
        // store link opens the App Store sheet, which the simulator cannot
        // load, so there the store URL leaves for the system instead.
        let sheetClose = app.buttons["playndgain.offer.close"]
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let appStore = XCUIApplication(bundleIdentifier: "com.apple.AppStore")
        if sheetClose.waitForExistence(timeout: 15) {
            XCTAssertTrue(app.webViews.firstMatch.exists)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertNotEqual(safari.state, .runningForeground, "the click must not leave for Safari")
            sleep(1)
            shot("03-click-browser-sheet")
            // Closing the sheet is the return from the offer: the reward check.
            sheetClose.tap()
            let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sheetClose)
            wait(for: [gone], timeout: 5)
        } else {
            XCTAssertTrue(safari.state == .runningForeground || appStore.state == .runningForeground, "no in-app outcome and no store fallback")
            shot("03-click-store-fallback")
            app.activate()
        }
        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 10))
        app.buttons["History"].tap()
        // A test-mode click is test earnings and History hides it, exactly as
        // the iframe's History does; the click row itself is checked on the
        // server (TESTING.md). Here: the History screen renders.
        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 10)
            || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Credited' OR label CONTAINS 'Started'")).firstMatch.waitForExistence(timeout: 2))
        shot("04-history")

        app.buttons["Close"].tap()
        let events = app.textViews.firstMatch
        XCTAssertTrue(events.waitForExistence(timeout: 5))
        let text = log(app)
        XCTAssertTrue(text.contains("didOpen"), text)
        XCTAssertEqual(text.components(separatedBy: "rewardCheck").count - 1, 1, "one reward check per click: \(text)")
        XCTAssertTrue(text.contains("didClose"), text)
    }

    /// The local demo offers redirect to a host that does not resolve: the
    /// click fails before any page. The wall stays, a sheet says the offer
    /// could not be opened, and there is no reward check.
    func testAClickThatReachesNothingKeepsTheWall() {
        let app = launch("IOS_FAIL")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Puzzle Quest,'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        let start = app.buttons["Start this offer"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.staticTexts["Offer unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["playndgain.offer.close"].exists)
        XCTAssertFalse(app.staticTexts["You are offline"].exists)
        shot("07-click-failed")
        // The notice's one way out.
        app.buttons["playndgain.detail.back"].tap()
        // The offer list is still there behind it.
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        let text = log(app)
        XCTAssertFalse(text.contains("rewardCheck"), text)
        XCTAssertTrue(text.contains("network"), text)
    }

    func testArabicIsRightToLeft() {
        let app = launch("IOS_AR", lang: "ar")
        XCTAssertTrue(app.buttons["العروض"].waitForExistence(timeout: 15))
        let offers = app.buttons["العروض"].frame
        let history = app.buttons["السجل"].frame
        // Mirrored: the first tab sits to the right of the second.
        XCTAssertGreaterThan(offers.minX, history.minX)
        shot("05-arabic-rtl")
    }

    func testBlockedNoticeOnEmulatorEvidence() throws {
        // Run with the wall's emulator_device rule on and a `dh` signature
        // configured for the simulator; see TESTING.md. Skipped otherwise.
        let app = launch("IOS_BLOCKED_PROBE")
        if app.staticTexts["Offers unavailable"].waitForExistence(timeout: 10) {
            shot("06-blocked")
        } else {
            throw XCTSkip("emulator rule not configured for the simulator in this run")
        }
    }
}
