import WebKit
import XCTest
@testable import Xtend

@MainActor
final class ExtensionSettingsPageTests: XCTestCase {
    private func package(popup: String? = nil, options: String? = nil,
                         optionsTab: Bool = false) throws -> ExtensionPackage {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for page in ["popup.html", "settings/index.html"] {
            let file = root.appendingPathComponent(page)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "<p>settings</p>".write(to: file, atomically: true, encoding: .utf8)
        }
        try "// content".write(to: root.appendingPathComponent("content.js"),
                                 atomically: true, encoding: .utf8)
        var json: [String: Any] = [
            "manifest_version": 3, "name": "Generic Settings Extension", "version": "1.0",
            "content_scripts": [["matches": ["https://x.com/*"], "js": ["content.js"]]]
        ]
        if let popup { json["action"] = ["default_popup": popup] }
        if let options { json["options_ui"] = ["page": options, "open_in_tab": optionsTab] }
        try JSONSerialization.data(withJSONObject: json).write(
            to: root.appendingPathComponent("manifest.json"))
        return try ExtensionPackage.installed(id: "generic-extension", root: root)
    }

    func testPopupIsSelectedWithoutExtensionSpecificCode() throws {
        let pkg = try package(popup: "popup.html")
        defer { try? FileManager.default.removeItem(at: pkg.root) }
        XCTAssertEqual(pkg.settingsPage?.path, "popup.html")
        XCTAssertEqual(pkg.settingsPage?.prefersWideLayout, false)
        let runtime = ExtensionRuntime(installedRoots: [pkg.id: pkg.root])
        let (config, host) = try runtime.makeSettingsConfiguration(for: pkg.id)
        XCTAssertNotNil(host)
        XCTAssertEqual(config.userContentController.userScripts.count, 1)
    }

    func testOptionsPageWithTabLayoutAndFallback() throws {
        let pkg = try package(popup: "popup.html", options: "settings/index.html", optionsTab: true)
        defer { try? FileManager.default.removeItem(at: pkg.root) }
        XCTAssertEqual(pkg.settingsPage?.path, "settings/index.html")
        XCTAssertEqual(pkg.settingsPage?.prefersWideLayout, true)
        let optionsOnly = try package(options: "settings/index.html")
        defer { try? FileManager.default.removeItem(at: optionsOnly.root) }
        XCTAssertEqual(optionsOnly.settingsPage?.path, "settings/index.html")
        // Even extensions opting out of Chrome's options tab get their wider
        // options page instead of a cramped toolbar popup inside Xtend.
        let embeddedOptions = try package(popup: "popup.html", options: "settings/index.html")
        defer { try? FileManager.default.removeItem(at: embeddedOptions.root) }
        XCTAssertEqual(embeddedOptions.settingsPage?.path, "settings/index.html")
        XCTAssertTrue(embeddedOptions.settingsPage?.prefersWideLayout == true)
    }

    func testUnsafeOrMissingSettingsPageIsNotExposed() throws {
        for invalid in ["../popup.html", "missing.html", "https://x.com/index.html", "popup.html?test=1"] {
            let pkg = try package(popup: invalid)
            XCTAssertNil(pkg.settingsPage)
            try FileManager.default.removeItem(at: pkg.root)
        }
        // A legacy popup.html is intentionally recognized even without manifest settings.
        let pkg = try package()
        defer { try? FileManager.default.removeItem(at: pkg.root) }
        XCTAssertEqual(pkg.settingsPage?.path, "popup.html")
    }

    func testUndeclaredPopupIsNotOfferedWhenFileIsMissing() throws {
        let pkg = try package()
        defer { try? FileManager.default.removeItem(at: pkg.root) }
        try FileManager.default.removeItem(at: pkg.root.appendingPathComponent("popup.html"))
        XCTAssertNil(pkg.settingsPage)
    }

    func testBrokenPopupFallsBackToValidOptionsPage() throws {
        let pkg = try package(popup: "missing.html", options: "settings/index.html")
        defer { try? FileManager.default.removeItem(at: pkg.root) }
        XCTAssertEqual(pkg.settingsPage?.path, "settings/index.html")
    }
}
