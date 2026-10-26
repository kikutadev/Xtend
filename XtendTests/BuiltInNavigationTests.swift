import WebKit
import XCTest
@testable import Xtend

@MainActor
final class BuiltInNavigationTests: XCTestCase {
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
