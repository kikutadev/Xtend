import XCTest
import UIKit
import ZIPFoundation
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

    func testReleaseCheckInstallAndRollbackWithSimulatedGitHub() async throws {
        let repo = try XCTUnwrap(GitHubReleaseRepository(input: "https://github.com/example/release.git"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtend-release-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            GitHubReleaseCredentials.remove()
        }

        func zip(version: String, name: String) throws -> Data {
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json: [String: Any] = [
                "manifest_version": 3, "name": name, "version": version,
                "content_scripts": [
                    ["matches": ["https://x.com/*"], "js": ["content.js"]]
                ]
            ]
            try JSONSerialization.data(withJSONObject: json).write(
                to: folder.appendingPathComponent("manifest.json"))
            try "document.body.dataset.xtendTest = '1';".write(
                to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
            let output = directory.appendingPathComponent(UUID().uuidString + ".zip")
            try FileManager.default.zipItem(at: folder, to: output)
            return try Data(contentsOf: output)
        }

        let name = "Xtend Release Integration Fixture"
        let oldZIP = directory.appendingPathComponent("original.zip")
        try zip(version: "0.1.0", name: name).write(to: oldZIP)
        let store = CommunityExtensionStore()
        let original = try store.installFromZIP(oldZIP)
        defer {
            try? store.uninstall(id: original.id)
            GitHubReleaseLinks.remove(original.id)
        }
        let stateKey = "xtend.extension.storage.\(original.id).local"
        UserDefaults.standard.set(Data("stored preferences".utf8), forKey: stateKey)
        defer { UserDefaults.standard.removeObject(forKey: stateKey) }

        MockGitHubReleaseProtocol.state.set(payload: try zip(version: "0.2.0", name: name))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockGitHubReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let available = try await GitHubReleaseInstaller.check(
            repository: repo, installedVersion: "0.1.0", installedTag: nil,
            tokenOverride: "fixture-token", session: session)
        XCTAssertEqual(available.release.tagName, "v0.2.0")
        XCTAssertTrue(available.needsUpdate)

        let installedTag = try await GitHubReleaseInstaller.installLatest(
            repository: repo, newToken: "fixture-token", existingID: original.id,
            session: session)
        XCTAssertEqual(installedTag, "v0.2.0")
        let root = try XCTUnwrap(store.installedRoots()[original.id])
        XCTAssertEqual(try CommunityExtensionStore.validateManifest(at: root).version, "0.2.0")
        XCTAssertEqual(UserDefaults.standard.data(forKey: stateKey), Data("stored preferences".utf8))
        XCTAssertEqual(GitHubReleaseLinks.get(original.id)?.installedTag, "v0.2.0")
        let currentCheck = try await GitHubReleaseInstaller.check(
            repository: repo, installedVersion: "0.2.0", installedTag: "v0.2.0",
            session: session)
        XCTAssertFalse(currentCheck.needsUpdate)

        MockGitHubReleaseProtocol.state.set(payload: try zip(
            version: "0.3.0", name: "A Different Extension"))
        do {
            _ = try await GitHubReleaseInstaller.installLatest(
                repository: repo, newToken: nil, existingID: original.id, session: session)
            XCTFail("A different extension must not replace the installed one")
        } catch GitHubReleaseError.unrelatedExtension {
            XCTAssertEqual(try CommunityExtensionStore.validateManifest(
                at: XCTUnwrap(store.installedRoots()[original.id])).version, "0.2.0")
            XCTAssertNotNil(UserDefaults.standard.data(forKey: stateKey))
        }
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


private final class MockGitHubReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(payload: Data) {
        lock.lock()
        value = payload
        lock.unlock()
    }
    func payload() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class MockGitHubReleaseProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockGitHubReleaseState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" else {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let isAsset = url.path.contains("/releases/assets/")
        let payload = Self.state.payload()
        let body: Data
        let contentType: String
        if isAsset {
            body = payload
            contentType = "application/zip"
        } else {
            let json = """
            {"tag_name":"v0.2.0","assets":[{"id":123,"name":"extension-chrome.zip","size":\(payload.count)}]}
            """
            body = Data(json.utf8)
            contentType = "application/json"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType,
                                                      "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
