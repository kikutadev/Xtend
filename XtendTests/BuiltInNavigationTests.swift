import WebKit
import XCTest
@testable import Xtend

@MainActor
final class BuiltInNavigationTests: XCTestCase {
    func testPromoPreferencesAndSettingsSwitchesApplyWithoutReload() throws {
        let keys = ["enabled", "getApp", "subscribe"].map { "xtend.hidePromotions." + $0 }
        let originals = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertTrue(XPromoPreferences.enabled)
        XCTAssertTrue(XPromoPreferences.getApp)
        XCTAssertTrue(XPromoPreferences.subscribe)

        var changes = 0
        let settings = ExtensionSettingsViewController(
            onReload: {}, onChange: {},
            onPromoPreferencesChanged: { changes += 1 }, onFinish: {})
        settings.loadViewIfNeeded()
        func toggle(_ identifier: String, in root: UIView) -> UISwitch? {
            if let control = root as? UISwitch, control.accessibilityIdentifier == identifier { return control }
            for child in root.subviews {
                if let control = toggle(identifier, in: child) { return control }
            }
            return nil
        }
        let master = try XCTUnwrap(toggle("xtend.cleanup.enabled", in: settings.view))
        let getApp = try XCTUnwrap(toggle("xtend.cleanup.getApp", in: settings.view))
        let subscribe = try XCTUnwrap(toggle("xtend.cleanup.subscribe", in: settings.view))
        XCTAssertTrue(master.isOn)
        XCTAssertTrue(getApp.isOn)
        XCTAssertTrue(subscribe.isOn)

        getApp.isOn = false
        getApp.sendActions(for: .valueChanged)
        XCTAssertFalse(XPromoPreferences.getApp)
        XCTAssertTrue(XPromoPreferences.subscribe)
        XCTAssertEqual(changes, 1)

        master.isOn = false
        master.sendActions(for: .valueChanged)
        XCTAssertFalse(XPromoPreferences.enabled)
        XCTAssertFalse(getApp.isEnabled)
        XCTAssertFalse(subscribe.isEnabled)
        XCTAssertEqual(changes, 2)

        master.isOn = true
        master.sendActions(for: .valueChanged)
        XCTAssertTrue(XPromoPreferences.enabled)
        XCTAssertFalse(XPromoPreferences.getApp)
        XCTAssertTrue(XPromoPreferences.subscribe)
        XCTAssertTrue(getApp.isEnabled)
        XCTAssertTrue(subscribe.isEnabled)
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(XPromoPreferences.javascriptObject,
                       "{enabled: true, getApp: false, subscribe: true}")
    }

    func testPromoFilterIsInjectedInTheExistingSettingsWorld() throws {
        let browser = BrowserViewController(initialURL: URL(string: "about:blank")!)
        browser.loadViewIfNeeded()
        let webView = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? WKWebView }.first)
        let scripts = webView.configuration.userContentController.userScripts
        let settingsScript = try XCTUnwrap(scripts.first { $0.source.contains("__xtendShowSettingsTip") })
        XCTAssertTrue(settingsScript.source.contains("__xtendPromoSettings"))
        XCTAssertTrue(settingsScript.source.contains("__xtendSetPromoSettings"))
        XCTAssertTrue(settingsScript.source.contains("data-xtend-hidden-menu-promo"))
        XCTAssertTrue(settingsScript.isForMainFrameOnly)
    }

    func testNavigationIsInstalledWithoutChromeExtensions() throws {
        let runtime = ExtensionRuntime(installedRoots: [:])
        let (configuration, host) = try runtime.makeBrowserConfiguration()
        XCTAssertNil(host)
        let scripts = configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.allSatisfy { $0.injectionTime == .atDocumentEnd && $0.isForMainFrameOnly })
        XCTAssertTrue(scripts.first?.source.contains("startSwipeNavigation(document)") == true)
        XCTAssertTrue(scripts.first?.source.contains("ScrollSnap-List") == true)
        XCTAssertTrue(scripts.last?.source.contains("quoteURLFor(button)") == true)
        XCTAssertTrue(scripts.last?.source.contains("/quotes") == true)
    }

    func testInstalledLegacySwipeIsIgnoredWithoutDisablingHealthyExtensions() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let oldSwipe = base.appendingPathComponent("x-swipe-navigation", isDirectory: true)
        let anchor = base.appendingPathComponent("x-home-anchor", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSwipe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version":3,"name":"X ホームの閲覧位置","version":"1.0",
         "content_scripts":[{"matches":["https://x.com/*"],"js":["content.js"],"run_at":"document_idle"}]}
        """
        try manifest.write(to: anchor.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "// fixture".write(to: anchor.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)

        let runtime = ExtensionRuntime(installedRoots: [
            "x-swipe-navigation": oldSwipe,
            ExtensionPackage.homeAnchorID: anchor
        ])
        XCTAssertEqual(runtime.packages.map(\.id), [ExtensionPackage.homeAnchorID])
        XCTAssertTrue(runtime.loadIssues.isEmpty)
        let (configuration, host) = try runtime.makeBrowserConfiguration()
        XCTAssertNotNil(host)
        XCTAssertEqual(configuration.userContentController.userScripts.filter {
            $0.source.contains("startSwipeNavigation(document)")
        }.count, 1)
        XCTAssertFalse(configuration.userContentController.userScripts.contains {
            $0.source.contains("xtendBridge_x_swipe_navigation")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSwipe.path))
    }

    func testNativeBackGestureDoesNotCompeteOnX() throws {
        let controller = BrowserViewController(initialURL: URL(string: "https://x.com/home")!)
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertFalse(browser.allowsBackForwardNavigationGestures)
    }

    func testExternalLoginPageKeepsWebViewBackGesture() throws {
        let controller = BrowserViewController(initialURL: URL(string: "about:blank")!)
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertTrue(browser.allowsBackForwardNavigationGestures)
    }
}
