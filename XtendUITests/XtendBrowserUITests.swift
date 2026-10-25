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

    private func captureBrowserEvidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    func testQuoteLongPressOnLoggedInX() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        // Previous sessions may leave X's profile drawer open. Accessibility
        // can still mark background repost controls as hittable underneath it.
        let drawerItem = web.staticTexts["Calls"]
        if drawerItem.exists && drawerItem.isHittable {
            // X closes the drawer on a leftward gesture inside the panel.
            let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.38))
            let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.38))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
        XCTAssertFalse(drawerItem.isHittable, "Close X's account drawer before selecting a post")
        sleep(2)
        let reposts = web.descendants(matching: .any).matching(NSPredicate(
            format: "label ENDSWITH[cd] %@ OR label ENDSWITH[cd] %@ OR label ENDSWITH[cd] %@",
            ". Repost", ". Undo repost", ". リポスト"
        ))
        var visibleRepost: XCUIElement?
        for attempt in 0..<7 {
            visibleRepost = (0..<min(reposts.count, 60))
                .map { reposts.element(boundBy: $0) }
                .first { $0.isHittable && $0.frame.width < 110 && $0.frame.height < 75 }
            if visibleRepost != nil { break }
            // Timeline posts may have images taller than the viewport.
            // Scroll until their action row enters the hit-testable area.
            web.swipeUp()
            if attempt > 2 { sleep(1) }
        }
        guard let repost = visibleRepost else {
            XCTFail("No visible X Repost button found in the live timeline")
            return
        }
        captureBrowserEvidence("quote-longpress-before")
        repost.press(forDuration: 0.8)
        XCTAssertTrue(web.staticTexts["Post activity"].waitForExistence(timeout: 12),
                      "Long press should open X's quote-posts activity screen")
        captureBrowserEvidence("quote-longpress-after")
        XCTAssertFalse(web.buttons["Quote"].isHittable,
                       "Long press must not open the quote composer menu")

        let backEdge = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.43))
        let backEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.43))
        backEdge.press(forDuration: 0.15, thenDragTo: backEnd)
        XCTAssertTrue(web.buttons["Following"].waitForExistence(timeout: 15) ||
                      web.buttons["For you"].exists,
                      "Back swipe should return to the original timeline")
        captureBrowserEvidence("quote-longpress-back")
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