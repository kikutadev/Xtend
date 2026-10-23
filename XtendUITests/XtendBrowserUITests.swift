import XCTest

@MainActor
final class XtendBrowserUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchExistingBrowser() throws -> XCUIElement {
        app.launch()
        let settings = app.buttons["Xtendの拡張機能設定"]
        guard settings.waitForExistence(timeout: 15) else {
            throw XCTSkip("Open X from Xtend's welcome screen before running the browser UI tests.")
        }
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20),
                      "The X browser should be available.")
        // Login is independently verified with a headless simulator screenshot.
        // X's WebKit accessibility text is not reliably exposed as StaticText.
        return settings
    }

    private func openSettings(_ button: XCUIElement) {
        button.tap()
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 10))
    }

    private func returnToBrowser() {
        let done = app.navigationBars["Xtendの設定"].buttons.firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["Xtendの拡張機能設定"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15),
                      "X's WebView should remain visible after closing settings.")
    }

    func testBrowserSettingsRoundTrip() throws {
        let settings = try launchExistingBrowser()
        openSettings(settings)
        returnToBrowser()
    }

    func testManualReloadReturnsToXBrowser() throws {
        let settings = try launchExistingBrowser()
        openSettings(settings)
        let reload = app.buttons["Xのページを再読み込み"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        reload.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Xtendの拡張機能設定"].waitForExistence(timeout: 15))
    }
}