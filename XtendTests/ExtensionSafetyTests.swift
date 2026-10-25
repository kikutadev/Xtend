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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(
            recorder, selector: #selector(StorageChangeRecorder.record(_:)),
            name: ExtensionStorage.didChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(recorder) }
        let writer = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let reader = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let separate = ExtensionStorage(extensionID: "extension-b", defaults: defaults, storageDirectory: directory)
        _ = try writer.set(area: "local", items: ["enabled": true])
        XCTAssertEqual(try reader.get(area: "local", keys: "enabled")["enabled"] as? Bool, true)
        XCTAssertNil(try separate.get(area: "local", keys: "enabled")["enabled"])
        XCTAssertEqual(recorder.extensionIDs, ["extension-a"])
        _ = try separate.set(area: "sync", items: ["count": 3])
        XCTAssertEqual(recorder.extensionIDs, ["extension-a", "extension-b"])
    }

    func testLocalAndSyncPersistAfterRecreatingStorage() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        _ = try writer.set(area: "local", items: ["history": ["names": ["alice": 123]], "option": true])
        _ = try writer.set(area: "sync", items: ["theme": "dark"])
        // File-backed writes must be visible to newly created storage without
        // waiting for preferences to flush or keeping a WebView alive.
        let restarted = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let local = try restarted.get(area: "local", keys: nil)
        XCTAssertNotNil((local["history"] as? [String: Any])?["names"])
        XCTAssertEqual(local["option"] as? Bool, true)
        XCTAssertEqual(try restarted.get(area: "sync", keys: "theme")["theme"] as? String, "dark")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        _ = try restarted.remove(area: "local", keys: "history")
        let afterRemoval = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertNil(try afterRemoval.get(area: "local", keys: "history")["history"])
        XCTAssertEqual(try afterRemoval.get(area: "local", keys: "option")["option"] as? Bool, true)
        XCTAssertEqual(try afterRemoval.get(area: "sync", keys: "theme")["theme"] as? String, "dark")
        XCTAssertNil(try ExtensionStorage(extensionID: "extension-b", defaults: defaults, storageDirectory: directory)
            .get(area: "local", keys: nil)["option"])
    }

    func testLegacyUserDefaultsMigratesWithoutLosingOrResurrectingValues() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let oldData = try JSONSerialization.data(withJSONObject: ["old": 1])
        defaults.set(oldData, forKey: "xtend.extension.storage.extension-a.local")
        let migrated = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertEqual(try migrated.get(area: "local", keys: "old")["old"] as? Int, 1)
        _ = try migrated.set(area: "local", items: ["new": 2])
        // Even if an earlier preference snapshot is still present, the file wins.
        defaults.set(oldData, forKey: "xtend.extension.storage.extension-a.local")
        let restarted = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertEqual(try restarted.get(area: "local", keys: "new")["new"] as? Int, 2)
        _ = try restarted.remove(area: "local", keys: ["old", "new"])
        XCTAssertTrue(try ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
            .get(area: "local", keys: nil).isEmpty)
    }

    func testFailedDiskWriteDoesNotReportSuccessOrNotify() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(recorder, selector: #selector(StorageChangeRecorder.record(_:)),
                                               name: ExtensionStorage.didChangeNotification, object: storage)
        defer { NotificationCenter.default.removeObserver(recorder) }
        XCTAssertThrowsError(try storage.set(area: "local", items: ["value": 1]))
        XCTAssertTrue(recorder.extensionIDs.isEmpty)
        XCTAssertNil(defaults.data(forKey: "xtend.extension.storage.extension-a.local"))
    }

    // Run 01 and 02 in separate xcodebuild invocations to verify persistence
    // across an actual test-host process boundary, not merely object recreation.
    private let restartSuite = "XtendCommonStorageProcessQA.v1"
    private let restartID = "xtend-test-extension-process-persistence"

    private var restartDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xtend/StorageProcessQA", isDirectory: true)
    }

    func test01WriteSharedStorageBeforeRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: restartSuite))
        defaults.removePersistentDomain(forName: restartSuite)
        try? FileManager.default.removeItem(at: restartDirectory)
        let storage = ExtensionStorage(extensionID: restartID, defaults: defaults, storageDirectory: restartDirectory)
        _ = try storage.set(area: "local", items: ["history": ["fixture": "persisted"]])
        _ = try storage.set(area: "sync", items: ["enabled": true])
        let files = try FileManager.default.contentsOfDirectory(at: restartDirectory,
                                                              includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { (try? Data(contentsOf: $0).isEmpty) == false })
        XCTAssertNil(defaults.data(forKey: "xtend.extension.storage.\(restartID).local"),
                     "The test must not accidentally pass through UserDefaults")
    }

    func test02ReadSharedStorageAfterRestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: restartSuite))
        defer {
            defaults.removePersistentDomain(forName: restartSuite)
            try? FileManager.default.removeItem(at: restartDirectory)
        }
        let storage = ExtensionStorage(extensionID: restartID, defaults: defaults, storageDirectory: restartDirectory)
        let history = try storage.get(area: "local", keys: "history")["history"] as? [String: Any]
        XCTAssertEqual(history?["fixture"] as? String, "persisted")
        XCTAssertEqual(try storage.get(area: "sync", keys: "enabled")["enabled"] as? Bool, true)
    }

    func testCorruptFileDoesNotSilentlyRestoreStalePreferences() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        _ = try storage.set(area: "local", items: ["current": true])
        let oldData = try JSONSerialization.data(withJSONObject: ["stale": true])
        defaults.set(oldData, forKey: "xtend.extension.storage.extension-a.local")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        try Data("invalid-json".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try storage.get(area: "local", keys: nil)) { error in
            XCTAssertEqual(error.localizedDescription, StorageError.corruptNamespace.localizedDescription)
        }
    }

    func testExtensionIDCannotEscapeStorageDirectory() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(extensionID: "../../../../../escape", storageDirectory: directory)
        _ = try storage.set(area: "local", items: ["safe": true])
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try XCTUnwrap(files.first).lastPathComponent.hasSuffix("-local.json"))
        XCTAssertEqual(try storage.get(area: "local", keys: "safe")["safe"] as? Bool, true)
    }

    func testUnchangedValueDoesNotBroadcast() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(
            recorder, selector: #selector(StorageChangeRecorder.record(_:)),
            name: ExtensionStorage.didChangeNotification, object: nil
        )
        defer { NotificationCenter.default.removeObserver(recorder) }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
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