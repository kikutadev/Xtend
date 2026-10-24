import WebKit
import XCTest
@testable import Xtend

@MainActor
final class EmbeddedSwipeConfigurationTests: XCTestCase {
    func testEmbeddedSwipeLoadsWhenNoExtensionsAreInstalled() throws {
        let runtime = ExtensionRuntime(installedRoots: [:])
        let (ordinary, ordinaryHost) = try runtime.makeBrowserConfiguration()
        XCTAssertNil(ordinaryHost)
        XCTAssertTrue(ordinary.userContentController.userScripts.isEmpty)

        let (embedded, embeddedHost) = try runtime.makeBrowserConfiguration(embeddedSwipe: true)
        XCTAssertNil(embeddedHost)
        let scripts = embedded.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts.first?.injectionTime, .atDocumentEnd)
        XCTAssertTrue(scripts.first?.isForMainFrameOnly == true)
        XCTAssertTrue(scripts.first?.source.contains("ScrollSnap-List") == true)
    }

    func testInstalledSwipeIsNotExecutedTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = root.appendingPathComponent("content-scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try """
        {"manifest_version":3,"name":"X Swipe Navigation","version":"0.1.0",
         "permissions":[],"content_scripts":[
           {"matches":["https://x.com/*","https://twitter.com/*"],
            "js":["content-scripts/content.js"],"run_at":"document_idle"}
         ]}
        """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "// fixture".write(
            to: content.appendingPathComponent("content.js"), atomically: true, encoding: .utf8
        )
        let runtime = ExtensionRuntime(installedRoots: [ExtensionPackage.swipeNavigationID: root])
        XCTAssertEqual(runtime.packages.map(\.id), [ExtensionPackage.swipeNavigationID])

        let (ordinary, ordinaryHost) = try runtime.makeBrowserConfiguration()
        XCTAssertNotNil(ordinaryHost)
        XCTAssertTrue(ordinary.userContentController.userScripts.contains {
            $0.source.contains("xtendBridge_x_swipe_navigation")
        })

        let (embedded, embeddedHost) = try runtime.makeBrowserConfiguration(embeddedSwipe: true)
        XCTAssertNil(embeddedHost)
        XCTAssertEqual(embedded.userContentController.userScripts.count, 1)
        XCTAssertFalse(embedded.userContentController.userScripts.contains {
            $0.source.contains("xtendBridge_x_swipe_navigation")
        })
    }
}
