import XCTest

@MainActor
final class XtendBrowserUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchExistingBrowser() throws {
        app.launch()
        guard app.webViews.firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Open X from Xtend's welcome screen before running browser UI tests.")
        }
    }

    private func settingsEntry() -> XCUIElement {
        let native = app.buttons["Xtendの拡張機能設定"]
        if native.exists && native.isHittable { return native }

        let web = app.webViews.firstMatch
        let entry = web.buttons["Xtendの設定"]
        if !entry.exists {
            // Xtend's ordinary settings entry belongs to X's profile drawer.
            let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
            let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
            edge.press(forDuration: 0.1, thenDragTo: open)
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Xtend settings must appear in the X drawer.")
        return entry
    }

    private func openSettings() {
        settingsEntry().tap()
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 10))
    }

    private func returnToBrowser() {
        let done = app.navigationBars["Xtendの設定"].buttons.firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15),
                      "X's WebView should remain visible after closing settings.")
    }

    func testBrowserSettingsRoundTrip() throws {
        try launchExistingBrowser()
        openSettings()
        returnToBrowser()
    }

    func testSwipeNavigationOnLoggedInX() throws {
        try runSwipeScenario()
    }

    private func runSwipeScenario() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        // Simulator evidence is captured for visual inspection because X's tab
        // selection is not consistently exposed through WebKit accessibility.
        func evidence(_ name: String) {
            XCTAssertEqual(app.state, .runningForeground, "Xtend must remain foreground after the gesture")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        try launchExistingBrowser()
        openSettings()
        let reload = app.buttons["Xのページを再読み込み"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        reload.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15))
    }
}