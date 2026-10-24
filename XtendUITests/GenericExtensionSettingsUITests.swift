import XCTest

@MainActor
final class GenericExtensionSettingsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMinimalThemeSettingsOpensFromInstalledExtensions() throws {
        app.launch()
        let web = app.webViews.firstMatch
        guard web.waitForExistence(timeout: 20) else {
            throw XCTSkip("An existing X login in the Simulator is required.")
        }

        let nativeSettings = app.buttons["Xtendの拡張機能設定"]
        if nativeSettings.isHittable {
            nativeSettings.tap()
        } else {
            let entry = web.buttons["Xtendの設定"]
            if !entry.exists || !entry.isHittable {
                let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
                let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
                start.press(forDuration: 0.12, thenDragTo: end)
            }
            XCTAssertTrue(entry.waitForExistence(timeout: 12), "Xtend settings entry must be accessible")
            entry.tap()
        }
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 12))

        let settings = app.buttons["Minimal Theme for Twitter / Xの設定"]
        if !settings.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 12), "Generic options entry is missing")
        XCTAssertTrue(settings.isHittable, "Generic options entry cannot be tapped")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Minimal Theme for Twitter / Xの設定"].waitForExistence(timeout: 12))
        let options = app.webViews.element(boundBy: max(app.webViews.count - 1, 0))
        XCTAssertTrue(options.waitForExistence(timeout: 12))
        XCTAssertTrue(options.staticTexts["Extension Enabled"].waitForExistence(timeout: 15),
                      "Minimal Theme options app failed to render")

        // Exit without changing the extension's settings.
        app.navigationBars["Minimal Theme for Twitter / Xの設定"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 8))
    }
}
