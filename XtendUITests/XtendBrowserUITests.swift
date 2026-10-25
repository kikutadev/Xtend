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

    // X's selected tab is not consistently exposed through WebKit accessibility.
    // Keep screenshots for comparing the before/after state of real X pages.
    private func captureBrowserEvidence(_ name: String) {
        XCTAssertEqual(app.state, .runningForeground,
                       "Xtend must remain foreground after the gesture")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func swipePageTab(in web: XCUIElement, y: CGFloat, left: Bool = true) {
        let start = web.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.78 : 0.20, dy: y))
        let end = web.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.17 : 0.80, dy: y))
        start.press(forDuration: 0.12, thenDragTo: end)
        sleep(2)
    }

    func testMenuPromotionsOnLoggedInX() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        sleep(4)
        captureBrowserEvidence("01-X-home-after-promo-filter")
        let visibleTopSubscribe = web.links.matching(identifier: "Subscribe")
            .allElementsBoundByIndex
            .filter { $0.isHittable }
        XCTAssertTrue(visibleTopSubscribe.isEmpty,
                      "The premium Subscribe banner must not remain on X home.")

        let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
        let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
        edge.press(forDuration: 0.1, thenDragTo: open)
        sleep(3)
        captureBrowserEvidence("02-X-drawer-promotions")
        XCTAssertTrue(web.buttons["Xtendの設定"].waitForExistence(timeout: 8),
                      "Real X drawer should be open before checking its items.")
        let candidates = web.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Get the app", "Subscribe"]))
            .allElementsBoundByIndex
            .filter { $0.isHittable }
            .map { $0.label }
        print("X_PROMO_VISIBLE_LABELS=\(candidates)")
        XCTAssertFalse(candidates.contains("Get the app"), "Get the app should not be visible")
    }

    func testBrowserSettingsRoundTrip() throws {
        try launchExistingBrowser()
        openSettings()
        returnToBrowser()
    }

    func testSettingsMenuWalkthroughAndRepeatedAccess() throws {
        app.launchArguments.append("--xtend-test-show-settings-tip")
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        let hint = web.staticTexts["← 設定"]
        XCTAssertTrue(hint.waitForExistence(timeout: 15),
                      "Highlight the profile menu without a text-heavy walkthrough.")
        XCTAssertFalse(app.buttons["Xtendの拡張機能設定"].isHittable,
                       "The native settings button must stay hidden on X home.")

        let entryEdge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
        let entryOpen = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
        entryEdge.press(forDuration: 0.1, thenDragTo: entryOpen)
        let entry = web.buttons["Xtendの設定"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "The highlighted menu must contain Xtend settings.")
        XCTAssertTrue(entry.isHittable)
        XCTAssertFalse(hint.exists, "The initial spotlight label must disappear after opening the drawer.")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Xtend settings spotlight in X drawer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        entry.tap()
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 8))
        returnToBrowser()
        let initialClose = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
        let initialCloseEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.17))
        initialClose.press(forDuration: 0.1, thenDragTo: initialCloseEnd)

        for index in 0..<4 {
            let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
            let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
            edge.press(forDuration: 0.1, thenDragTo: open)
            let entry = web.buttons["Xtendの設定"]
            XCTAssertTrue(entry.waitForExistence(timeout: 8), "Menu entry missing in cycle \(index).")
            XCTAssertTrue(entry.isHittable, "Menu entry obscured in cycle \(index).")
            XCTAssertEqual(web.buttons.matching(identifier: "Xtendの設定").count, 1,
                           "Menu entry duplicated after reopening.")

            entry.tap()
            XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 8),
                          "Settings did not open in cycle \(index).")
            returnToBrowser()

            let close = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
            let closeEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.17))
            close.press(forDuration: 0.1, thenDragTo: closeEnd)
            XCTAssertTrue(web.exists)
        }
    }

    func testSwipeNavigationOnLoggedInX() throws {
        try runSwipeScenario()
    }

    private func runSwipeScenario() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        // Let the X home feed hydrate before receiving synthetic touch input.
        sleep(5)
        captureBrowserEvidence("01-before")
        let leftStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.16))
        let leftEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.16))
        leftStart.press(forDuration: 0.1, thenDragTo: leftEnd)
        sleep(3)
        captureBrowserEvidence("02-timeline-left")
        XCTAssertTrue(web.exists)

        let rightStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.21, dy: 0.16))
        let rightEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.16))
        rightStart.press(forDuration: 0.1, thenDragTo: rightEnd)
        sleep(3)
        captureBrowserEvidence("03-timeline-right")

        // X owns the drawer DOM; Xtend owns the edge gesture.
        let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
        let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
        edge.press(forDuration: 0.1, thenDragTo: open)
        sleep(2)
        captureBrowserEvidence("04-menu-open")
        XCTAssertTrue(web.buttons["Xtendの設定"].waitForExistence(timeout: 8),
                      "Home edge swipe must open the profile drawer.")
        let close = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
        let closeEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.17))
        close.press(forDuration: 0.1, thenDragTo: closeEnd)
        sleep(2)
        captureBrowserEvidence("05-menu-close")
        XCTAssertFalse(web.buttons["Xtendの設定"].isHittable,
                       "Closing the drawer must return control to the timeline.")
        XCTAssertTrue(web.exists)
    }

    func testOtherPageTabsOnLoggedInX() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch

        sleep(4)
        captureBrowserEvidence("home-start")
        let notifications = web.coordinate(withNormalizedOffset: CGVector(dx: 0.71, dy: 0.954))
        notifications.tap()
        sleep(4)
        captureBrowserEvidence("notifications-before")
        swipePageTab(in: web, y: 0.22)
        captureBrowserEvidence("notifications-left")
        swipePageTab(in: web, y: 0.22, left: false)
        captureBrowserEvidence("notifications-right")

        // The drawer edge gesture belongs to /home only. Return home first.
        let home = web.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.954))
        home.tap()
        sleep(3)
        captureBrowserEvidence("home-before-menu")
        let edge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.42))
        let open = web.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.42))
        edge.press(forDuration: 0.1, thenDragTo: open)
        sleep(2)
        captureBrowserEvidence("profile-menu")
        // In mobile X, "Profile" is duplicated in the accessibility tree.
        // Tap the visible first drawer row at ~21% of the WebView height.
        let topMenuProfile = web.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.21))
        topMenuProfile.tap()
        sleep(4)
        captureBrowserEvidence("profile-before")
        swipePageTab(in: web, y: 0.36)
        captureBrowserEvidence("profile-left-y36")
        swipePageTab(in: web, y: 0.55)
        captureBrowserEvidence("profile-left-y55")
        swipePageTab(in: web, y: 0.55, left: false)
        captureBrowserEvidence("profile-right-y55")
        swipePageTab(in: web, y: 0.55, left: false)
        captureBrowserEvidence("profile-right-again-y55")
    }

    func testDeveloperTouchVisualizationSettings() throws {
        try launchExistingBrowser()
        let browser = app.webViews.firstMatch
        let home = browser.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.95))
        home.tap()
        sleep(3)
        openSettings()

        let toggle = app.switches["xtend.developer.showTouches"]
        let settingsScroll = app.scrollViews.firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            settingsScroll.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable, "Developer touch option should be accessible from Xtend settings.")
        let original = toggle.value as? String == "1"

        if !original { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        returnToBrowser()

        let web = app.webViews.firstMatch
        let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.4))
        let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4))
        start.press(forDuration: 0.4, thenDragTo: end)
        captureBrowserEvidence("developer-touch-visualization")

        home.tap()
        sleep(2)
        openSettings()
        for _ in 0..<8 where !toggle.isHittable {
            settingsScroll.swipeUp()
        }
        XCTAssertEqual(toggle.value as? String, "1", "Developer option must remain enabled when settings reopens.")
        if !original { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, original ? "1" : "0")
        returnToBrowser()
    }

    func testHistoryEdgesOnLoggedInX() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        sleep(3)

        // Two non-home SPA routes leave both WebKit history gestures enabled.
        let notifications = web.coordinate(withNormalizedOffset: CGVector(dx: 0.71, dy: 0.954))
        notifications.tap()
        sleep(3)
        captureBrowserEvidence("history-notifications")

        let search = web.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.954))
        search.tap()
        sleep(3)
        captureBrowserEvidence("history-search")

        let backEdge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
        let backEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.76, dy: 0.44))
        backEdge.press(forDuration: 0.15, thenDragTo: backEnd)
        sleep(3)
        captureBrowserEvidence("history-back")
        XCTAssertTrue(web.staticTexts["Notifications"].waitForExistence(timeout: 8),
                      "Back swipe must return to notifications, not merely preserve the WebView.")

        let forwardEdge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.44))
        let forwardEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.44))
        forwardEdge.press(forDuration: 0.15, thenDragTo: forwardEnd)
        sleep(3)
        captureBrowserEvidence("history-forward")
        XCTAssertTrue(web.staticTexts["Explore"].waitForExistence(timeout: 8),
                      "Forward swipe must return to search, not switch to another X tab.")

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