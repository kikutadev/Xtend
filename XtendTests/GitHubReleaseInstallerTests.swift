import XCTest
import UIKit
@testable import Xtend

final class GitHubReleaseInstallerTests: XCTestCase {
    func testRepositoryURLsAcceptOnlyGitHubRepositories() {
        for raw in [
            "https://github.com/example-org/demo-extension",
            "https://github.com/example-org/demo-extension/releases",
            "https://github.com/example-org/demo-extension/releases/latest",
            "https://github.com/example-org/demo-extension/releases/tag/v0.1.0",
            "https://github.com/example-org/demo-extension.git",
            "git@github.com:example-org/demo-extension.git",
            "ssh://git@github.com/example-org/demo-extension.git"
        ] {
            let repo = GitHubReleaseRepository(input: raw)
            XCTAssertEqual(repo?.owner, "example-org")
            XCTAssertEqual(repo?.name, "demo-extension")
            XCTAssertEqual(repo?.apiURL.absoluteString,
                           "https://api.github.com/repos/example-org/demo-extension/releases/latest")
        }
        for raw in [
            "http://github.com/example/repo",
            "https://github.com.evil.example/example/repo",
            "https://github.com/example/repo?token=x",
            "https://github.com/example/repo/issues",

            "https://user:pass@github.com/example/repo",
            "https://github.com/example/../another",
            "https://github.com/example/repo/other/path",
            "https://github.com/example/repo#extra",
            "git@github.com.evil.example:example/repo.git",
            "git@github.com:example/../secret.git",
            "ssh://other@github.com/example/repo.git",
            "https://github.com/example/repo.git?access_token=secret"
        ] {
            XCTAssertNil(GitHubReleaseRepository(input: raw), raw)
        }
    }

    func testVersionComparisonAndSavedSource() {
        XCTAssertFalse(GitHubReleaseVersion.needsUpdate(
            installed: "0.1.0", latestTag: "v0.1.0", installedTag: nil))
        XCTAssertTrue(GitHubReleaseVersion.needsUpdate(
            installed: "0.1.0", latestTag: "v0.2.0", installedTag: nil))
        XCTAssertFalse(GitHubReleaseVersion.needsUpdate(
            installed: "2.1.0", latestTag: "v1.9.0", installedTag: nil))
        XCTAssertFalse(GitHubReleaseVersion.needsUpdate(
            installed: "0.1.0", latestTag: "v0.1.0", installedTag: "v0.1.0"))
        XCTAssertTrue(GitHubReleaseVersion.needsUpdate(
            installed: "0.1.0", latestTag: "v0.2.0", installedTag: "v0.1.0"))
        XCTAssertFalse(GitHubReleaseVersion.needsUpdate(
            installed: "2.0.0", latestTag: "v1.0.0", installedTag: "v0.9.0"))

        let id = "test-github-source-\(UUID().uuidString)"
        defer { GitHubReleaseLinks.remove(id) }
        let repository = GitHubReleaseRepository(input: "git@github.com:example/repo.git")!
        GitHubReleaseLinks.save(id: id, repository: repository, tag: "v0.1.0")
        XCTAssertEqual(GitHubReleaseLinks.get(id)?.repository, "https://github.com/example/repo")
        XCTAssertEqual(GitHubReleaseLinks.get(id)?.installedTag, "v0.1.0")
    }

    func testGitHubTokenUsesDeviceKeychain() throws {
        defer { GitHubReleaseCredentials.remove() }
        GitHubReleaseCredentials.remove()
        XCTAssertNil(GitHubReleaseCredentials.load())
        try GitHubReleaseCredentials.save("test-only-token")
        XCTAssertEqual(GitHubReleaseCredentials.load(), "test-only-token")
        GitHubReleaseCredentials.remove()
        XCTAssertNil(GitHubReleaseCredentials.load())
    }

    @MainActor
    func testInstalledExtensionOffersManualReleaseCheck() {
        let view = InstalledExtensionsListView()
        let sample = InstalledExtensionInfo(id: "zip-fixture", name: "Demo Extension",
                                            version: "1.0.0", icon: nil, issue: nil)
        var received: String?
        view.onCheckRelease = { received = $0.id }
        view.update(items: [sample])
        func buttons(in root: UIView) -> [UIButton] {
            let nested = root.subviews.flatMap { buttons(in: $0) }
            return ((root as? UIButton).map { [$0] } ?? []) + nested
        }
        let button = buttons(in: view).first {
            $0.accessibilityLabel == "Demo Extensionの更新を確認"
        }
        XCTAssertNotNil(button)
        button?.sendActions(for: .touchUpInside)
        XCTAssertEqual(received, sample.id)
    }

    func testLatestReleaseSelectsPackagedChromeZIP() throws {
        let json = #"{"tag_name":"v1.2.3","assets":[{"id":1,"name":"CHANGELOG.zip","size":120},{"id":2,"name":"extension-1.2.3-chrome.zip","size":2048},{"id":3,"name":"SHA256SUMS","size":100}]}"#
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.tagName, "v1.2.3")
        XCTAssertEqual(try release.extensionZIP().id, 2)
    }

    func testAmbiguousOrMissingZIPIsRejected() throws {
        let multiple = GitHubRelease(tagName: "v2", assets: [
            .init(id: 1, name: "extension-a.zip", size: 1024),
            .init(id: 2, name: "extension-b.zip", size: 1024)
        ])
        XCTAssertThrowsError(try multiple.extensionZIP())
        let sourcesOnly = GitHubRelease(tagName: "v2", assets: [
            .init(id: 3, name: "Source code", size: 800)
        ])
        XCTAssertThrowsError(try sourcesOnly.extensionZIP())
        let one = GitHubRelease(tagName: "v3", assets: [
            .init(id: 8, name: "app.zip", size: ExtensionInstallStore.maximumPackageBytes + 1),
            .init(id: 9, name: "release-3.zip", size: 45)
        ])
        XCTAssertEqual(try one.extensionZIP().id, 9)
    }
}
