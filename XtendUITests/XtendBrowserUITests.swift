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

    func testSwipeNavigationOnLoggedInX() throws {
        try runSwipeScenario()
    }

    func testEmbeddedSwipeNavigationOnLoggedInX() throws {
        app.launchArguments = ["--xtend-embedded-swipe"]
        try runSwipeScenario()
    }

    func testSwipeExtensionWithNativeBackGestureDisabled() throws {
        app.launchArguments = ["--xtend-swipe-back-disabled"]
        try runSwipeScenario()
    }

    private func runSwipeScenario() throws {
        _ = try launchExistingBrowser()
        let web = app.webViews.firstMatch
        // Simulator evidence is captured for visual inspection because X's tab
        // selection is not consistently exposed through WebKit accessibility.
        func evidence(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // Let the X home feed hydrate before receiving synthetic touch input.
        sleep(5)
        evidence("01-before")
        let leftStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.34))
        let leftEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.34))
        leftStart.press(forDuration: 0.1, thenDragTo: leftEnd)
        sleep(3)
        evidence("02-timeline-left")
        XCTAssertTrue(web.exists)

        let rightStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.21, dy: 0.34))
        let rightEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.34))
        rightStart.press(forDuration: 0.1, thenDragTo: rightEnd)
        sleep(3)
        evidence("03-timeline-right")

        // X mobile owns the drawer DOM, the extension owns the edge gesture.
        let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
        let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
        edge.press(forDuration: 0.1, thenDragTo: open)
        sleep(2)
        evidence("04-menu-open")
        let close = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
        let closeEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.17))
        close.press(forDuration: 0.1, thenDragTo: closeEnd)
        sleep(2)
        evidence("05-menu-close")
        XCTAssertTrue(web.exists)
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