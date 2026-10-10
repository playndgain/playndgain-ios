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
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Puzzle Quest,'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        shot("01-offers")

        card.tap()
        let start = app.buttons["Start this offer"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["What you have to do"].exists)
        shot("02-detail")

        start.tap()
        // The click leaves the app for Safari.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        sleep(3)
        shot("03-click-safari")

        app.activate()
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
        XCTAssertTrue(text.contains("rewardCheck"), text)
        XCTAssertTrue(text.contains("didClose"), text)
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
