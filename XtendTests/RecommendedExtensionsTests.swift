import XCTest
import UIKit
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
