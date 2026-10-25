import XCTest
@testable import Xtend

final class GitHubReleaseInstallerTests: XCTestCase {
    func testRepositoryURLsAcceptOnlyGitHubRepositories() {
        for raw in [
            "https://github.com/example-org/demo-extension",
            "https://github.com/example-org/demo-extension/releases",
            "https://github.com/example-org/demo-extension/releases/latest",
            "https://github.com/example-org/demo-extension/releases/tag/v0.1.0"
        ] {
            let repo = GitHubReleaseRepository(url: URL(string: raw)!)
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
            "https://github.com/example/repo#extra"
        ] {
            XCTAssertNil(GitHubReleaseRepository(url: URL(string: raw)!), raw)
        }
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
