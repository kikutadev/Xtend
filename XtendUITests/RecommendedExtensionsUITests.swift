import XCTest

@MainActor
final class RecommendedExtensionsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecommendationsAppearOnWelcomeAndOfferInstallation() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["おすすめChrome拡張機能"].waitForExistence(timeout: 15))
        let ad = app.buttons["xtend.recommend.install.X Ad Hider"]
        scrollUntilVisible(ad)
        XCTAssertTrue(ad.exists && ad.isHittable && ad.isEnabled)
        XCTAssertTrue(app.buttons["xtend.recommend.install.X Timeline Filter"].exists)
        XCTAssertTrue(app.buttons["xtend.recommend.install.にゃっとランドforX"].exists)
        XCTAssertTrue(app.staticTexts["x-home-anchor"].exists)
        attachScreenshot("recommended-before-install")
    }

    func testPrivateRecommendationOpensAuthenticatedInstallForm() throws {
        app.launch()
        let ad = app.buttons["xtend.recommend.install.X Ad Hider"]
        scrollUntilVisible(ad)
        XCTAssertTrue(ad.isHittable && ad.isEnabled)
        ad.tap()
        let url = app.textFields["拡張機能のURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        XCTAssertEqual(url.value as? String, "https://github.com/kikutadev/x-ad-hider")
        XCTAssertTrue(app.secureTextFields["GitHubの読み取り用トークン"].exists)
        attachScreenshot("private-recommendation-token-input")
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
