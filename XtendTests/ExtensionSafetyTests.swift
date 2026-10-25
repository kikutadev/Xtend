import Foundation
import UIKit
import WebKit
import XCTest
@testable import Xtend

@MainActor
private final class StorageChangeRecorder: NSObject {
    var extensionIDs: [String] = []
    @objc func record(_ notification: Notification) {
        if let id = notification.userInfo?["extensionID"] as? String {
            extensionIDs.append(id)
        }
    }
}

@MainActor
final class ExtensionStorageTests: XCTestCase {
    func testCrossInstanceValuesAndChangeIdentity() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(
            recorder, selector: #selector(StorageChangeRecorder.record(_:)),
            name: ExtensionStorage.didChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(recorder) }
        let writer = ExtensionStorage(extensionID: "extension-a", defaults: defaults)
        let reader = ExtensionStorage(extensionID: "extension-a", defaults: defaults)
        let separate = ExtensionStorage(extensionID: "extension-b", defaults: defaults)
        _ = try writer.set(area: "local", items: ["enabled": true])
        XCTAssertEqual(try reader.get(area: "local", keys: "enabled")["enabled"] as? Bool, true)
        XCTAssertNil(try separate.get(area: "local", keys: "enabled")["enabled"])
        XCTAssertEqual(recorder.extensionIDs, ["extension-a"])
        _ = try separate.set(area: "sync", items: ["count": 3])
        XCTAssertEqual(recorder.extensionIDs, ["extension-a", "extension-b"])
    }

    func testUnchangedValueDoesNotBroadcast() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(
            recorder, selector: #selector(StorageChangeRecorder.record(_:)),
            name: ExtensionStorage.didChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(recorder) }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults)
        _ = try storage.set(area: "local", items: ["theme": "dark"])
        _ = try storage.set(area: "local", items: ["theme": "dark"])
        XCTAssertEqual(recorder.extensionIDs, ["extension-a"])
    }
}

final class ExtensionPackageValidationTests: XCTestCase {
    func testIncompleteNyattoPackageIsRejectedBeforeInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = """
        {
          "manifest_version": 3, "name": "Nyatto Test", "version": "1.0",
          "permissions": ["storage"],
          "content_scripts": [
            {"matches": ["https://x.com/*"], "js": ["inject.js", "xff-asset-loader.js"]},
            {"matches": ["https://x.com/*"], "js": ["content.js"]}
          ]
        }
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for filename in ["inject.js", "xff-asset-loader.js", "content.js"] {
            try "// fixture".write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        XCTAssertThrowsError(try ExtensionInstallStore.readAndValidateManifest(at: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("popup.html"))
        }
    }

    func testIncompleteHomeAnchorPackageIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = """
        {
          "manifest_version": 3, "name": "X ホームの閲覧位置", "version": "1.0",
          "content_scripts": [
            {"matches": ["https://x.com/*"], "js": ["content.js"], "run_at": "document_idle"}
          ]
        }
        """
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try XHomeAnchorInstallStore.validateManifest(at: dir))
    }
}

@MainActor
final class ExtensionRuntimeRecoveryTests: XCTestCase {
    func testBrokenNyattoDoesNotDisableHealthyHomeAnchor() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let badNyatto = base.appendingPathComponent("broken-nyatto")
        let goodAnchor = base.appendingPathComponent("home-anchor")
        try FileManager.default.createDirectory(at: badNyatto, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: goodAnchor, withIntermediateDirectories: true)
        try "invalid manifest".write(
            to: badNyatto.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        let manifest = """
        {
          "manifest_version": 3, "name": "X ホームの閲覧位置", "version": "1.0",
          "content_scripts": [
            {"matches": ["https://x.com/*"], "js": ["content.js"], "run_at": "document_idle"}
          ]
        }
        """
        try manifest.write(
            to: goodAnchor.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        try "// fixture".write(
            to: goodAnchor.appendingPathComponent("content.js"),
            atomically: true, encoding: .utf8
        )
        let runtime = ExtensionRuntime(installedRoots: [
            ExtensionInstallStore.supportedExtensionID: badNyatto,
            ExtensionPackage.homeAnchorID: goodAnchor
        ])
        XCTAssertEqual(runtime.packages.map(\.id), [ExtensionPackage.homeAnchorID])
        XCTAssertNotNil(runtime.loadIssues[ExtensionInstallStore.supportedExtensionID])
        XCTAssertNil(runtime.loadIssues[ExtensionPackage.homeAnchorID])
        let (_, host) = try runtime.makeBrowserConfiguration()
        XCTAssertNotNil(host)
    }

    func testBothBrokenExtensionsAllowPlainWebView() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let runtime = ExtensionRuntime(installedRoots: [
            ExtensionInstallStore.supportedExtensionID: first,
            ExtensionPackage.homeAnchorID: second
        ])
        XCTAssertTrue(runtime.packages.isEmpty)
        XCTAssertEqual(runtime.loadIssues.count, 2)
        let (_, host) = try runtime.makeBrowserConfiguration()
        XCTAssertNil(host)
    }
}

final class ExtensionUpdateRecoveryTests: XCTestCase {
    func testInterruptedReplacementRestoresPreviousPackage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let backup = dir.appendingPathComponent(".previous-test", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try "original".write(to: backup.appendingPathComponent("marker"), atomically: true, encoding: .utf8)

        try ExtensionInstallStore.recoverInterruptedReplacement(
            directory: dir, name: "installed-extension", backupPrefix: ".previous-", fileManager: fm
        )
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("installed-extension/marker").path))
        XCTAssertFalse(fm.fileExists(atPath: backup.path))
    }

    func testExistingReplacementIsNeverOverwrittenByBackup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("installed-extension", isDirectory: true)
        let backup = dir.appendingPathComponent(".previous-test", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try ExtensionInstallStore.recoverInterruptedReplacement(
            directory: dir, name: "installed-extension", backupPrefix: ".previous-", fileManager: fm
        )
        XCTAssertTrue(fm.fileExists(atPath: destination.path))
        XCTAssertTrue(fm.fileExists(atPath: backup.path))
    }
}

final class ExtensionArchiveSafetyTests: XCTestCase {
    private func archiveURL(base64: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url
    }

    func testTraversalPathIsRejected() throws {
        let url = try archiveURL(base64: "UEsDBBQAAAAAAAAAIQDuQOUFBwAAAAcAAAAOAAAALi4vb3V0c2lkZS50eHRmaXh0dXJlUEsBAhQDFAAAAAAAAAAhAO5A5QUHAAAABwAAAA4AAAAAAAAAAAAAAKSBAAAAAC4uL291dHNpZGUudHh0UEsFBgAAAAABAAEAPAAAADMAAAAAAA==")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ExtensionInstallStore.validateArchive(at: url))
    }

    func testSymbolicLinkIsRejected() throws {
        let url = try archiveURL(base64: "UEsDBBQAAAAAAAAAIQCqPsY+CwAAAAsAAAAEAAAAbGlua2Rlc3RpbmF0aW9uUEsBAhQDFAAAAAAAAAAhAKo+xj4LAAAACwAAAAQAAAAAAAAAAAAAAP+hAAAAAGxpbmtQSwUGAAAAAAEAAQAyAAAALQAAAAAA")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ExtensionInstallStore.validateArchive(at: url))
    }

    func testOrdinaryArchivePassesStructuralValidation() throws {
        let url = try archiveURL(base64: "UEsDBBQAAAAAAAAAIQDuQOUFBwAAAAcAAAAGAAAAb2sudHh0Zml4dHVyZVBLAQIUAxQAAAAAAAAAIQDuQOUFBwAAAAcAAAAGAAAAAAAAAAAAAACkgQAAAABvay50eHRQSwUGAAAAAAEAAQA0AAAAKwAAAAAA")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try ExtensionInstallStore.validateArchive(at: url))
    }
}
/// Simulator QA using the installed, unmodified Nyatto extension and Xtend's actual WebKit bridge.
/// Run write and read in separate xcodebuild test invocations to cross a real app process boundary.
@MainActor
final class NyattoRingPersistenceTests: XCTestCase {
    private let extensionID = ExtensionInstallStore.supportedExtensionID
    private let suite = "XtendRingPersistenceRestartQA.v1"
    private let fixtureAccount = "xtend_fixture_liker"

    private func javascript(_ script: String, in view: WKWebView, world: WKContentWorld) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: String(describing: value))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 14,
                           condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "NyattoRingPersistenceQA", code: 1)
    }

    private func fixture() throws -> (WKWebView, ExtensionHost, UIWindow, UserDefaults, WKContentWorld) {
        guard let root = ExtensionInstallStore().existingRoot else {
            throw XCTSkip("Nyatto must be staged in the Simulator app's Extensions directory")
        }
        let package = try ExtensionPackage.installed(id: extensionID, root: root)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let host = try ExtensionHost(packages: [package], storageByID: [
            extensionID: ExtensionStorage(extensionID: extensionID, defaults: defaults)
        ])
        let config = WKWebViewConfiguration()
        try host.installBrowserRuntime(into: config)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = WKWebView(frame: controller.view.bounds, configuration: config)
        controller.view.addSubview(view)
        host.attach(to: view)
        view.loadHTMLString("<!doctype html><html><head></head><body><main id='qa'>Xtend ring storage QA</main></body></html>",
                            baseURL: URL(string: "https://x.com/home")!)
        return (view, host, window, defaults, ExtensionPackage.contentWorld(for: extensionID))
    }

    private func storedHistory(in defaults: UserDefaults) -> [String: Any]? {
        let key = "xtend.extension.storage.\(extensionID).local"
        guard let data = defaults.data(forKey: key),
              let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return all["xff:liked-by"] as? [String: Any]
    }

    func test01WriteHistoryBeforeRestart() async throws {
        let (view, host, window, defaults, world) = try fixture()
        _ = host
        defer { window.isHidden = true }
        defaults.removePersistentDomain(forName: suite)
        try await waitUntil("Nyatto browser runtime") {
            (try? await self.javascript("typeof globalThis.XFFStorage + ':' + location.hostname", in: view, world: world)) == "object:x.com"
        }
        _ = try await javascript("globalThis.XFFStorage.update('xff:liked-by', old => ({version:1, names:{...(old?.names||{}), xtend_fixture_liker: Date.now()}, ids:{}}), ok => {globalThis.__xtendSaved=ok}); 'written'", in: view, world: world)
        try await waitUntil("native storage persisted") {
            let history = self.storedHistory(in: defaults)
            return (history?["names"] as? [String: Any])?[self.fixtureAccount] != nil
        }
        let savedCallback = try await javascript("String(globalThis.__xtendSaved)", in: view, world: world)
        XCTAssertEqual(savedCallback, "true")
        XCTAssertTrue(defaults.synchronize())
    }

    func test02ReadHistoryAfterProcessRestart() async throws {
        let (view, host, window, defaults, world) = try fixture()
        _ = host
        defer { window.isHidden = true }
        XCTAssertNotNil((storedHistory(in: defaults)?["names"] as? [String: Any])?[fixtureAccount],
                        "History must survive termination between the two tests")
        try await waitUntil("Nyatto browser runtime") {
            (try? await self.javascript("typeof globalThis.XFFStorage + ':' + location.hostname", in: view, world: world)) == "object:x.com"
        }
        _ = try await javascript("globalThis.XFFStorage.read(['xff:liked-by'], data => {globalThis.__xtendRestored = Boolean(data['xff:liked-by']?.names?.xtend_fixture_liker)}); 'reading'", in: view, world: world)
        try await waitUntil("history restored via Chrome API") {
            (try? await self.javascript("String(globalThis.__xtendRestored)", in: view, world: world)) == "true"
        }
        defaults.removePersistentDomain(forName: suite)
    }
}
