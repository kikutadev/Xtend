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

    /// Dismiss overlays X may restore on launch; otherwise swipes hit the
    /// drawer while the test incorrectly reports the browser is alive.
    private func dismissXOverlays(in web: XCUIElement) {
        sleep(5)
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.69, dy: 0.94)).tap()
        sleep(1)
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.44)).tap()
        sleep(1)
        if web.buttons["Xtendの設定"].exists {
            let from = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.17))
            let to = web.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.17))
            from.press(forDuration: 0.1, thenDragTo: to)
            sleep(2)
        }
    }

    func testBetaTimelinePreloadOnActualX() throws {
        app.launchArguments.append(contentsOf: ["--xtend-test-beta-preload", "--xtend-test-beta-audit"])
        try launchExistingBrowser()
        sleep(17)
        let active = app.webViews["Xtend.ActiveTimelineWebView"]
        XCTAssertTrue(active.waitForExistence(timeout: 12))
        // The background timeline must not be reachable by accessibility.
        XCTAssertFalse(app.webViews["Xtend.StandbyTimelineWebView"].exists)
        dismissXOverlays(in: active)
        captureBrowserEvidence("beta-initial")
        let currentForYou = active.buttons["For you"].isSelected
        let currentFollowing = active.buttons["Following"].isSelected
        XCTAssertTrue(currentForYou || currentFollowing, "Visible X must have a selected home tab")
        active.coordinate(withNormalizedOffset: CGVector(dx: currentForYou ? 0.32 : 0.12, dy: 0.09)).tap()
        captureBrowserEvidence("beta-immediate-after-first-switch")
        sleep(2)
        captureBrowserEvidence("beta-switched")
        XCTAssertTrue(app.webViews["Xtend.ActiveTimelineWebView"].buttons[currentForYou ? "Following" : "For you"].isSelected,
                      "Beta must switch to the prefetched X timeline")
        let newActive = app.webViews["Xtend.ActiveTimelineWebView"]
        newActive.coordinate(withNormalizedOffset: CGVector(dx: currentForYou ? 0.12 : 0.32, dy: 0.09)).tap()
        captureBrowserEvidence("beta-immediate-after-return")
        sleep(2)
        XCTAssertTrue(app.webViews["Xtend.ActiveTimelineWebView"].buttons[currentForYou ? "For you" : "Following"].isSelected,
                      "Beta must return to the previously loaded X timeline")
        print("BETA_ROUND_TRIP passed")
    }

    func testTimelineSwitchOnActualX() throws {
        try launchExistingBrowser()
        let web = app.webViews.firstMatch
        dismissXOverlays(in: web)
        let following = web.buttons.matching(NSPredicate(
            format: "label ==[cd] %@ OR label ==[cd] %@", "Following", "フォロー中"
        )).firstMatch
        let forYou = web.buttons.matching(NSPredicate(
            format: "label ==[cd] %@ OR label ==[cd] %@", "For you", "おすすめ"
        )).firstMatch
        captureBrowserEvidence("01-live-X-after-drawer-dismissed")
        print("LIVE_TABS initial following=\(following.exists) forYou=\(forYou.exists) followingSelected=\(following.exists ? following.isSelected : false)")
        XCTAssertTrue(following.waitForExistence(timeout: 8),
                      "X home Following tab must be visible before testing a timeline swipe")
        XCTAssertTrue(forYou.exists, "X home For you tab must be visible")
        if following.isSelected { forYou.tap() }
        captureBrowserEvidence("02-live-X-for-you")
        let leftStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.34))
        let leftEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.34))
        leftStart.press(forDuration: 0.1, thenDragTo: leftEnd)
        sleep(2)
        captureBrowserEvidence("03-live-X-following-after-swipe")
        print("LIVE_TABS left followingSelected=\(following.isSelected) forYouSelected=\(forYou.isSelected)")
        XCTAssertTrue(following.isSelected, "X Following tab must be selected after swipe left")
        let rightStart = web.coordinate(withNormalizedOffset: CGVector(dx: 0.21, dy: 0.34))
        let rightEnd = web.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.34))
        rightStart.press(forDuration: 0.1, thenDragTo: rightEnd)
        sleep(2)
        captureBrowserEvidence("04-live-X-for-you-after-return")
        print("LIVE_TABS right followingSelected=\(following.isSelected) forYouSelected=\(forYou.isSelected)")
        XCTAssertTrue(forYou.isSelected, "X For you tab must be selected after swipe right")
        XCTAssertTrue(web.exists)
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
        // Persisted X sessions can restore the profile drawer on launch.
        // Dismiss it using the dimmed region; hidden accessibility nodes are
        // still sometimes reported as hittable.
        sleep(2)
        web.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.43)).tap()
        sleep(1)
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
            web.swipeUp()
            if attempt > 2 { sleep(1) }
        }
        guard let repost = visibleRepost else {
            captureBrowserEvidence("quote-no-repost-control")
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

        // X handles its own back stack, which can return via post details.
        // UI acceptance here tests the quote view and absence of the repost menu;
        // X's back arrows are checked separately in the live manual scenario.
    }

    func testNyattoUpdateCheckUsesWebStoreInsteadOfGitHub() throws {
        try launchExistingBrowser()
        openSettings()
        let update = app.buttons["にゃっとランドforXの更新を確認"]
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where !update.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(update.waitForExistence(timeout: 10), "Installed Nyatto needs a manual update check")
        update.tap()
        XCTAssertFalse(app.alerts["にゃっとランドforXのGitHub取得元"].exists,
                       "Web Store extensions must not ask for a GitHub clone URL")
        XCTAssertFalse(app.textFields["GitHubクローンURL"].exists)
        captureBrowserEvidence("nyatto-webstore-update-check")
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