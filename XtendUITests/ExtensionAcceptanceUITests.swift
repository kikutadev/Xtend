import XCTest

@MainActor
final class ExtensionAcceptanceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "org.example.xtend.acceptance")
    private let storeURL = "https://chromewebstore.google.com/detail/minimal-theme-for-twitter-x/pobhoodpcipjmedfenaigbeloiidbflp"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openXtendSettings() {
        let native = app.buttons["Xtendの拡張機能設定"]
        if native.isHittable {
            native.tap()
            return
        }
        let web = app.webViews.firstMatch
        let entry = web.buttons["Xtendの設定"]
        if !entry.exists {
            let start = web.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.44))
            let end = web.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.44))
            start.press(forDuration: 0.12, thenDragTo: end)
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 12), "Xtend settings entry was not found")
        entry.tap()
    }

    func testWebStoreInstallFromWelcomeAndRemoveThroughSettings() throws {
        app.launch()

        // Run only against a new QA bundle ID, never a personal Xtend installation.
        let welcome = app.staticTexts["Chrome拡張機能を追加"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "A fresh Xtend app is required for this acceptance test")

        let field = app.textFields["Chrome拡張機能のURL"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText(storeURL)
        let install = app.buttons["インストール"]
        XCTAssertTrue(install.isEnabled)
        install.tap()

        let installedName = app.staticTexts["Minimal Theme for Twitter / X"]
        XCTAssertTrue(installedName.waitForExistence(timeout: 120),
                      "Chrome Web Store install failed: \(app.debugDescription)")

        let openX = app.buttons["Xを見る"]
        XCTAssertTrue(openX.waitForExistence(timeout: 10))
        openX.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 40))

        openXtendSettings()
        XCTAssertTrue(app.navigationBars["Xtendの設定"].waitForExistence(timeout: 10))
        XCTAssertTrue(installedName.waitForExistence(timeout: 15))

        let remove = app.buttons["Minimal Theme for Twitter / Xを削除"]
        if !remove.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let confirm = app.alerts.buttons["削除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertFalse(installedName.waitForExistence(timeout: 3),
                       "The removed extension is still listed")

        let done = app.navigationBars["Xtendの設定"].buttons.firstMatch
        done.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        openXtendSettings()
        XCTAssertTrue(app.staticTexts["インストール済みの拡張機能はありません。"].waitForExistence(timeout: 10))
    }
}
