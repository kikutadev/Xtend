import XCTest
import UIKit
import ZIPFoundation
@testable import Xtend

@MainActor
final class RecommendedExtensionsTests: XCTestCase {
    func testRecommendedInstallUsesExistingURLInstaller() throws {
        let view = RecommendedExtensionsView()
        var received: String?
        view.onInstallURL = { received = $0 }

        let ad = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.X Ad Hider"))
        ad.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, "https://github.com/kikutadev/x-ad-hider")

        let filter = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.X Timeline Filter"))
        filter.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, "https://github.com/kikutadev/x-timeline-filter")

        let nyatto = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.にゃっとランドforX"))
        nyatto.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, ExtensionInstallStore.defaultStoreURL.absoluteString)
    }

    func testNyattoInstallShowsWebStoreGuidanceWithoutGitHubToken() throws {
        let view = ExtensionInstallFormView()
        let field = try XCTUnwrap(view.arrangedSubviews.compactMap { $0 as? UITextField }.first)
        let note = try XCTUnwrap(view.arrangedSubviews.compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "xtend.install.source-note" })
        let token = try XCTUnwrap(view.arrangedSubviews.compactMap { $0 as? UITextField }
            .first { $0.accessibilityLabel == "GitHubの読み取り用トークン" })

        XCTAssertTrue(note.text?.contains("Chrome Web Store") == true)
        XCTAssertFalse(note.text?.contains("GitHub") == true)
        XCTAssertTrue(token.isHidden)

        field.text = ExtensionInstallStore.defaultStoreURL.absoluteString
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(note.text?.contains("Chrome Web Store") == true)
        XCTAssertFalse(note.text?.contains("GitHub") == true)
        XCTAssertTrue(token.isHidden)

        field.text = "https://github.com/kikutadev/x-ad-hider"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(note.text?.contains("GitHub") == true)
        XCTAssertFalse(token.isHidden)
    }

    func testUpdateSourceSelectionPreservesChromeWebStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Legacy Nyatto installations had no metadata and must never ask for a GitHub URL.
        XCTAssertEqual(InstalledExtensionCatalog.chromeWebStoreURL(
            for: ExtensionInstallStore.supportedExtensionID, root: root),
            ExtensionInstallStore.defaultStoreURL)
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let url = URL(string: "https://chromewebstore.google.com/detail/example/\(id)")!
        let metadata = ExtensionInstallMetadata(id: id, version: "1.0.0", source: .chromeWebStore(url))
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent(".xtend-install.json"))
        XCTAssertEqual(InstalledExtensionCatalog.chromeWebStoreURL(for: id, root: root), url)
        // A GitHub/ZIP source must not be misclassified as a Web Store extension.
        XCTAssertNil(InstalledExtensionCatalog.chromeWebStoreURL(for: "different-extension", root: root))
    }

    func testWebStoreVersionInspectionDoesNotInstallPackage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let extensionRoot = folder.appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: extensionRoot, withIntermediateDirectories: true)
        let manifest = """
            {"manifest_version":3,"name":"Demo X Tool","version":"2.3.1",
             "content_scripts":[{"matches":["https://x.com/*"],"js":["content.js"]}]}
            """
        try manifest.write(to: extensionRoot.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
        try "console.log('test');".write(to: extensionRoot.appendingPathComponent("content.js"),
                                       atomically: true, encoding: .utf8)
        let archive = folder.appendingPathComponent("package.zip")
        try FileManager.default.zipItem(at: extensionRoot, to: archive)
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let source = URL(string: "https://chromewebstore.google.com/detail/demo/\(id)")!
        let checked = try ExtensionURLInstaller.inspectWebStorePayload(Data(contentsOf: archive), storeURL: source)
        XCTAssertEqual(checked.version, "2.3.1")
        XCTAssertEqual(checked.extensionID, id)
        XCTAssertEqual(checked.storeURL, source)
    }

    func testInstalledAndBusyRecommendationsCannotInstallAgain() throws {
        let view = RecommendedExtensionsView()
        let nyatto = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.にゃっとランドforX"))
        let ad = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.X Ad Hider"))
        XCTAssertTrue(nyatto.isEnabled)
        XCTAssertTrue(ad.isEnabled)

        view.updateInstalled(items: [
            InstalledExtensionInfo(id: ExtensionInstallStore.supportedExtensionID,
                                   name: "にゃっとランドforX", version: "1.0",
                                   icon: nil, issue: nil)
        ])
        XCTAssertFalse(nyatto.isEnabled)
        XCTAssertTrue(ad.isEnabled)

        view.setBusy(true)
        XCTAssertFalse(ad.isEnabled)
        view.setBusy(false)
        XCTAssertTrue(ad.isEnabled)
    }

    func testGitHubRecommendationRecognizesExistingInstallation() throws {
        let view = RecommendedExtensionsView()
        let id = "test-recommendation-" + UUID().uuidString
        defer { GitHubReleaseLinks.remove(id) }
        let repository = try XCTUnwrap(GitHubReleaseRepository(input: "https://github.com/kikutadev/x-ad-hider"))
        GitHubReleaseLinks.save(id: id, repository: repository, tag: "v0.1.0")
        view.updateInstalled(items: [
            InstalledExtensionInfo(id: id, name: "X Ad Hider",
                                   version: "0.1.0", icon: nil, issue: nil)
        ])
        let ad = try XCTUnwrap(button(in: view, id: "xtend.recommend.install.X Ad Hider"))
        XCTAssertFalse(ad.isEnabled)
    }

    private func button(in view: UIView, id: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id {
            return button
        }
        for child in view.subviews {
            if let button = button(in: child, id: id) { return button }
        }
        return nil
    }
}
