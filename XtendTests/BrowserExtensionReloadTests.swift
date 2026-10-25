import UIKit
import WebKit
import XCTest
@testable import Xtend

@MainActor
final class BrowserExtensionReloadTests: XCTestCase {
    private func makeBrowser() throws -> (BrowserViewController, WKWebView) {
        let controller = BrowserViewController(initialURL: URL(string: "about:blank"))
        controller.loadViewIfNeeded()
        let webView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        return (controller, webView)
    }

    private func activeWebView(_ controller: BrowserViewController) throws -> WKWebView {
        try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
    }

    func testClosingSettingsWithoutChangesKeepsWebView() throws {
        let (controller, original) = try makeBrowser()
        controller.applyExtensionChanges()
        XCTAssertTrue(try activeWebView(controller) === original)
    }

    func testSeveralConfigurationChangesRebuildOnce() throws {
        let (controller, original) = try makeBrowser()
        controller.markExtensionConfigurationChanged()
        controller.markExtensionConfigurationChanged()
        controller.applyExtensionChanges()
        let replacement = try activeWebView(controller)
        XCTAssertFalse(replacement === original)
        XCTAssertEqual(controller.view.subviews.compactMap { $0 as? WKWebView }.count, 1)

        controller.applyExtensionChanges()
        XCTAssertTrue(try activeWebView(controller) === replacement)
    }

    func testExplicitReloadStillWorksWithoutChanges() throws {
        let (controller, original) = try makeBrowser()
        controller.applyExtensionChanges(force: true)
        XCTAssertFalse(try activeWebView(controller) === original)
    }
}
