import XCTest

@MainActor
final class RecommendedExtensionsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecommendationsAppearOnWelcomeAndOfferInstallation() throws {
        app.launch()
        guard app.staticTexts["おすすめChrome拡張機能"].waitForExistence(timeout: 15) else {
            throw XCTSkip("First-launch welcome screen is required for this visual test.")
        }
        let ad = app.buttons["xtend.recommend.install.X Ad Hider"]
        scrollUntilVisible(ad)
        XCTAssertTrue(ad.exists && ad.isHittable)
        XCTAssertTrue(app.buttons["xtend.recommend.install.X Timeline Filter"].exists)
        XCTAssertTrue(app.buttons["xtend.recommend.install.にゃっとランドforX"].exists)
        XCTAssertTrue(app.staticTexts["x-home-anchor"].exists)
        attachScreenshot("recommended-before-install")
    }

    func testPublicGitHubReleasesInstallAndPersist() throws {
        app.launch()
        guard app.staticTexts["おすすめChrome拡張機能"].waitForExistence(timeout: 15) else {
            throw XCTSkip("Run install acceptance in an app with the welcome screen visible.")
        }
        let versions = app.staticTexts.matching(identifier: "バージョン 0.1.0")
        for name in ["X Ad Hider", "X Timeline Filter"] {
            let add = app.buttons["xtend.recommend.install.\(name)"]
            scrollUntilVisible(add)
            XCTAssertTrue(add.isHittable, "\(name) recommendation should be visible")
            if add.isEnabled { add.tap() }
            let installed = app.buttons["\(name)は追加済み"]
            XCTAssertTrue(installed.waitForExistence(timeout: 50),
                          "\(name) did not install from public GitHub Release")
            XCTAssertFalse(installed.isEnabled)
            XCTAssertTrue(app.staticTexts[name].exists)
            attachScreenshot("installed-\(name)")
        }
        XCTAssertGreaterThanOrEqual(versions.count, 2)
        app.terminate()
        app.launch()
        for name in ["X Ad Hider", "X Timeline Filter"] {
            let installed = app.buttons["\(name)は追加済み"]
            XCTAssertTrue(installed.waitForExistence(timeout: 15),
                          "\(name) installation must survive app restart")
            XCTAssertFalse(installed.isEnabled)
        }
        let continueToX = app.buttons["Xを見る"]
        scrollUntilVisible(continueToX)
        XCTAssertTrue(continueToX.isHittable)
        continueToX.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 25),
                      "Xtend WKWebView did not launch with both extensions installed")
        attachScreenshot("browser-with-public-extensions")
    }

    func testInstalledTimelineFilterSettingsRendersInXtend() throws {
        app.launch()
        let web = app.webViews.firstMatch
        guard web.waitForExistence(timeout: 25) else {
            throw XCTSkip("Launch X after installing the Timeline Filter first.")
        }
        let native = app.buttons["Xtendの拡張機能設定"]
        if native.isHittable {
            native.tap()
        } else {
            let entry = web.buttons["Xtendの設定"]
            if !entry.isHittable {
                let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
                let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
                start.press(forDuration: 0.12, thenDragTo: end)
            }
            XCTAssertTrue(entry.waitForExistence(timeout: 20))
            entry.tap()
        }
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 15))
        let filterOptions = app.buttons["X Timeline Filterの設定"]
        scrollUntilVisible(filterOptions)
        XCTAssertTrue(filterOptions.isHittable, "Installed popup settings entry must be tappable")
        filterOptions.tap()
        XCTAssertTrue(app.navigationBars["X Timeline Filterの設定"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["アカウント許可リスト"].waitForExistence(timeout: 15),
                      "Extension popup should execute its JavaScript inside Xtend")
        XCTAssertTrue(app.staticTexts["フィルター OFF"].exists,
                      "Timeline filter must remain off before explicit user activation")
        attachScreenshot("timeline-filter-settings-render")
    }

    private func scrollUntilVisible(_ element: XCUIElement) {
        let list = app.scrollViews.firstMatch
        for _ in 0..<9 {
            if element.isHittable { return }
            list.swipeUp()
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
