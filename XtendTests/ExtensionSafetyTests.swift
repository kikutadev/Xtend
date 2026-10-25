import Foundation
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