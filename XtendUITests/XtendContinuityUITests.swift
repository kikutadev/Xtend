import XCTest

/// Headless visual regression for Xtend's existing WebView replacement path.
/// Uses the logged-in X session when present; does not modify extensions.
@MainActor
final class XtendContinuityUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testScrolledXFeedBeforeAndAfterWebViewRebuild() throws {
        app.launch()
        let settings = app.buttons["Xtendの拡張機能設定"]
        guard settings.waitForExistence(timeout: 15) else {
            throw XCTSkip("Xtend browser is not initialized on this simulator.")
        }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        sleep(7) // X feed hydration
        for _ in 0..<3 {
            web.swipeUp()
            sleep(1)
        }
        sleep(2)
        capture("01-scrolled-before-reload")

        settings.tap()
        let reload = app.buttons["Xのページを再読み込み"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        capture("02-settings-before-reload")
        reload.tap()
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        sleep(10) // X timeline rehydration and bounded restoration retries
        capture("03-scrolled-after-reload")
        XCTAssertTrue(settings.exists, "Xtend must remain operable after rebuilding WebView.")
    }
}
