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
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.injectionTime, .atDocumentEnd)
        XCTAssertEqual(scripts.first?.isForMainFrameOnly, true)
        XCTAssertTrue(scripts.first?.source.contains("startSwipeNavigation(document)") == true)
        XCTAssertTrue(scripts.first?.source.contains("ScrollSnap-List") == true)
    }

    func testSettingsMenuUsesBundledScriptInIsolatedWorld() throws {
        for showTip in [false, true] {
            let configuration = WKWebViewConfiguration()
            try XtendSettingsMenu.install(into: configuration, showTip: showTip) { _ in }

            let script = try XCTUnwrap(configuration.userContentController.userScripts.first)
            XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
            XCTAssertEqual(script.injectionTime, .atDocumentEnd)
            XCTAssertTrue(script.isForMainFrameOnly)
            XCTAssertTrue(script.source.hasPrefix(
                "const __xtendShowSettingsTip = \(showTip ? "true" : "false");\n"
            ))
            XCTAssertTrue(script.source.contains("xtend-native-settings-entry"))
            XCTAssertTrue(script.source.contains("xtend-settings-tip"))
            XCTAssertTrue(script.source.contains("bridge.postMessage({ action: 'open' })"))
        }
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

    func testHomeReservesLeftEdgeForDrawer() throws {
        let controller = BrowserViewController(initialURL: URL(string: "https://x.com/home")!)
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertFalse(browser.allowsBackForwardNavigationGestures)
        XCTAssertEqual(enabledHistoryEdges(on: browser), 0)
    }

    func testNonHomeXPagesKeepWebViewHistoryGestures() throws {
        for path in ["/notifications", "/explore", "/sample/status/123", "/sample", "/i/flow/login"] {
            let controller = BrowserViewController(initialURL: URL(string: "https://x.com\(path)")!)
            controller.loadViewIfNeeded()
            let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
            XCTAssertFalse(browser.allowsBackForwardNavigationGestures)
            XCTAssertEqual(enabledHistoryEdges(on: browser), 2, "History edge pans must work at \(path)")
        }
    }

    func testWebViewURLTracksHistoryAPIRouteChanges() throws {
        let webView = WKWebView()
        let didLoad = expectation(description: "Synthetic page loaded")
        let observer = NavigationLoadedObserver { _ in
            didLoad.fulfill()
        }
        webView.navigationDelegate = observer
        webView.loadHTMLString("<html><body>route fixture</body></html>",
                               baseURL: URL(string: "https://x.com/home"))
        wait(for: [didLoad], timeout: 10)

        let didEvaluate = expectation(description: "SPA navigation completed")
        webView.evaluateJavaScript("history.pushState({}, '', '/sample/status/123'); location.pathname") {
            result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? String, "/sample/status/123")
            XCTAssertEqual(webView.url?.path, "/sample/status/123")
            didEvaluate.fulfill()
        }
        wait(for: [didEvaluate], timeout: 10)
    }

    func testHistoryGesturesFollowSPARouteChanges() throws {
        let controller = BrowserViewController(initialURL: URL(string: "about:blank")!)
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        let loaded = expectation(description: "X home fixture loaded")
        let observer = NavigationLoadedObserver { page in
            if page.url?.host == "x.com" && page.url?.path == "/home" {
                loaded.fulfill()
            }
        }
        browser.navigationDelegate = observer
        browser.loadHTMLString("<html><body>SPA fixture</body></html>",
                               baseURL: URL(string: "https://x.com/home"))
        wait(for: [loaded], timeout: 10)
        // loadHTMLString initially exposes about:blank as WKWebView.url.
        // Route it to /home through History API, as X does internally.
        let homed = expectation(description: "SPA entered home")
        browser.evaluateJavaScript("history.replaceState({}, '', '/home')") { _, error in
            XCTAssertNil(error)
            homed.fulfill()
        }
        wait(for: [homed], timeout: 10)
        waitForHistoryGesture(on: browser, enabled: false)

        let pushed = expectation(description: "Opened a post through pushState")
        browser.evaluateJavaScript("history.pushState({}, '', '/sample/status/123')") {
            _, error in
            XCTAssertNil(error)
            pushed.fulfill()
        }
        wait(for: [pushed], timeout: 10)
        waitForHistoryGesture(on: browser, enabled: true)
        XCTAssertTrue(browser.canGoBack, "SPA post navigation must create WebKit back history")

        let backed = expectation(description: "Returned home through history")
        browser.evaluateJavaScript("history.back()") { _, error in
            XCTAssertNil(error)
            backed.fulfill()
        }
        wait(for: [backed], timeout: 10)
        waitForHistoryGesture(on: browser, enabled: false)
        XCTAssertTrue(browser.canGoForward, "WebKit should offer forward history after returning home")
        browser.goForward()
        waitForHistoryGesture(on: browser, enabled: true)
        XCTAssertEqual(browser.url?.path, "/sample/status/123")
    }

    private func waitForHistoryGesture(on browser: WKWebView, enabled: Bool) {
        let condition = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !browser.allowsBackForwardNavigationGestures &&
                    self.enabledHistoryEdges(on: browser) == (enabled ? 2 : 0)
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [condition], timeout: 5), .completed,
                       "Expected history gesture enabled=\(enabled) at \(browser.url?.absoluteString ?? "nil")")
    }

    private func enabledHistoryEdges(on browser: WKWebView) -> Int {
        (browser.gestureRecognizers ?? [])
            .compactMap { $0 as? UIScreenEdgePanGestureRecognizer }
            .filter { $0.name?.hasPrefix("xtend.history.") == true && $0.isEnabled }
            .count
    }

    func testExternalLoginPageKeepsWebViewBackGesture() throws {
        let controller = BrowserViewController(initialURL: URL(string: "about:blank")!)
        controller.loadViewIfNeeded()
        let browser = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertTrue(browser.allowsBackForwardNavigationGestures)
        XCTAssertEqual(enabledHistoryEdges(on: browser), 0)
    }
}


@MainActor
private final class NavigationLoadedObserver: NSObject, WKNavigationDelegate {
    private let onLoad: (WKWebView) -> Void
    private var didReport = false

    init(onLoad: @escaping (WKWebView) -> Void) {
        self.onLoad = onLoad
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didReport else { return }
        if webView.url?.host == "x.com" && webView.url?.path == "/home" {
            didReport = true
            onLoad(webView)
        }
    }
}
