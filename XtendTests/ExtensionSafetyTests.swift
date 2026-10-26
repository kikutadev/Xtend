import CryptoKit
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
        // SQLite writes must be visible to another instance and across process restarts.
        let restarted = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let local = try restarted.get(area: "local", keys: nil)
        XCTAssertNotNil((local["history"] as? [String: Any])?["names"])
        XCTAssertEqual(local["option"] as? Bool, true)
        XCTAssertEqual(try restarted.get(area: "sync", keys: "theme")["theme"] as? String, "dark")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("extension-storage.sqlite").path))
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
        let file = restartDirectory.appendingPathComponent("extension-storage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)
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

    func testMergesFileAndPreferencesWithoutDiscardingUniqueKeys() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data("extension-a".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("\(hash)-local.json")
        try JSONSerialization.data(withJSONObject: ["follower-older": ["alice"], "overlap": "file"])
            .write(to: file, options: .atomic)
        defaults.set(try JSONSerialization.data(withJSONObject: ["following-newer": ["bob"],
                                                                     "overlap": "preferences"]),
                     forKey: "xtend.extension.storage.extension-a.local")
        let migrated = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let all = try migrated.get(area: "local", keys: nil)
        XCTAssertEqual((all["follower-older"] as? [String])?.count, 1)
        XCTAssertEqual((all["following-newer"] as? [String])?.count, 1)
        XCTAssertEqual(all["overlap"] as? String, "file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(defaults.data(forKey: "xtend.extension.storage.extension-a.local"))
        let reloaded = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertEqual((try reloaded.get(area: "local", keys: "following-newer")["following-newer"]
                       as? [String])?.first, "bob")
    }

    func testCorruptLegacyFileDoesNotSilentlyRestoreStalePreferences() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileHash = SHA256.hash(data: Data("extension-a".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("\(fileHash)-local.json")
        try Data("invalid-json".utf8).write(to: file)
        defaults.set(try JSONSerialization.data(withJSONObject: ["stale": true]),
                     forKey: "xtend.extension.storage.extension-a.local")
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertThrowsError(try storage.get(area: "local", keys: nil)) { error in
            XCTAssertEqual(error.localizedDescription, StorageError.corruptNamespace.localizedDescription)
        }
        // Correcting the bad file allows a one-time import, not fallback to preferences.
        try JSONSerialization.data(withJSONObject: ["fromFile": true]).write(to: file, options: .atomic)
        XCTAssertEqual(try storage.get(area: "local", keys: "fromFile")["fromFile"] as? Bool, true)
        XCTAssertEqual(try storage.get(area: "local", keys: "stale")["stale"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExtensionIDCannotEscapeStorageDirectory() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(extensionID: "../../../../../escape", storageDirectory: directory)
        _ = try storage.set(area: "local", items: ["safe": true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("extension-storage.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("escape").path))
        XCTAssertEqual(try storage.get(area: "local", keys: "safe")["safe"] as? Bool, true)
    }

    func testSQLiteBackendUpdateLatencyWith8MiBHistory() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let block = String(repeating: "0123456789abcdef", count: 65_536)
        for i in 0..<8 { _ = try storage.set(area: "local", items: ["history-\(i)": block]) }
        var writes: [Double] = [], reads: [Double] = []
        for i in 0..<80 {
            let begin = ProcessInfo.processInfo.systemUptime
            _ = try storage.set(area: "local", items: ["activity": "2026-10-26-\(i)"])
            writes.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
            let readStart = ProcessInfo.processInfo.systemUptime
            XCTAssertNotNil(try storage.get(area: "local", keys: "activity")["activity"])
            reads.append((ProcessInfo.processInfo.systemUptime - readStart) * 1000)
        }
        writes.sort(); reads.sort()
        print(String(format: "SQLITE_EXTENSION_STORAGE_8MIB updateMedianMs=%.3f readMedianMs=%.3f updateP95Ms=%.3f",
                     writes[40], reads[40], writes[76]))
        XCTAssertNotNil(try ExtensionStorage(extensionID: "extension-a", defaults: defaults,
                                           storageDirectory: directory).get(area: "local", keys: "history-0")["history-0"])
    }

    func testUninstallErasesBothAreasAndCannotResurrectLegacyData() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let other = ExtensionStorage(extensionID: "extension-b", defaults: defaults, storageDirectory: directory)
        _ = try storage.set(area: "local", items: ["activity": ["alice", "bob"]])
        _ = try storage.set(area: "sync", items: ["enabled": true])
        _ = try other.set(area: "local", items: ["protected": "another extension"])
        // Simulate lingering preferences written just before uninstall.
        let old = try JSONSerialization.data(withJSONObject: ["stale": true])
        defaults.set(old, forKey: "xtend.extension.storage.extension-a.local")
        try storage.eraseAll()
        XCTAssertNil(defaults.data(forKey: "xtend.extension.storage.extension-a.local"))
        // An old preference snapshot reappearing after a crash must not be imported.
        defaults.set(old, forKey: "xtend.extension.storage.extension-a.local")
        let reinstalled = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        XCTAssertTrue(try reinstalled.get(area: "local", keys: nil).isEmpty)
        XCTAssertTrue(try reinstalled.get(area: "sync", keys: nil).isEmpty)
        XCTAssertEqual(try other.get(area: "local", keys: "protected")["protected"] as? String,
                       "another extension")
    }

    func testLargeOpaqueJSONValueAndReadVariants() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let payload = String(repeating: "0123456789abcdef", count: 786_432) // 12 MiB
        _ = try storage.set(area: "local", items: ["large": payload, "number": 3, "bool": false,
                                                    "null": NSNull(), "nested": ["a": ["b", 12]]])
        XCTAssertEqual((try storage.get(area: "local", keys: "large")["large"] as? String)?.count,
                       12 * 1024 * 1024)
        let slice = try storage.get(area: "local", keys: ["number", "bool", "missing"])
        XCTAssertEqual(slice.count, 2)
        XCTAssertEqual(slice["number"] as? Int, 3)
        XCTAssertEqual(slice["bool"] as? Bool, false)
        let defaultsQuery = try storage.get(area: "local", keys: ["missing": "fallback", "number": 0])
        XCTAssertEqual(defaultsQuery["missing"] as? String, "fallback")
        XCTAssertEqual(defaultsQuery["number"] as? Int, 3)
        XCTAssertTrue((try storage.get(area: "local", keys: nil)["null"]) is NSNull)
        _ = try storage.remove(area: "local", keys: ["large", "number", "large"])
        XCTAssertNil(try storage.get(area: "local", keys: "large")["large"])
        XCTAssertNotNil(try storage.get(area: "local", keys: "nested")["nested"])
    }

    func testInvalidBatchDoesNotWriteSomeKeysOrNotify() throws {
        let suite = "XtendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = ExtensionStorage(extensionID: "extension-a", defaults: defaults, storageDirectory: directory)
        let recorder = StorageChangeRecorder()
        NotificationCenter.default.addObserver(recorder, selector: #selector(StorageChangeRecorder.record(_:)),
                                               name: ExtensionStorage.didChangeNotification, object: storage)
        defer { NotificationCenter.default.removeObserver(recorder) }
        XCTAssertThrowsError(try storage.set(area: "local", items: ["valid": 2, "invalid": Date()]))
        XCTAssertTrue(try storage.get(area: "local", keys: nil).isEmpty)
        XCTAssertTrue(recorder.extensionIDs.isEmpty)
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
/// Mobile X does not render the desktop profile link expected by Nyatto.
/// These tests use the installed extension with Xtend's isolated WebKit world.
@MainActor
final class MobileViewerCompatibilityTests: XCTestCase {
    private let extensionID = ExtensionInstallStore.supportedExtensionID

    private func fixture(html: String) throws -> (WKWebView, ExtensionHost, UIWindow, ExtensionStorage, URL, UserDefaults, String) {
        guard let root = ExtensionInstallStore().existingRoot else {
            throw XCTSkip("Nyatto must be installed in the Simulator app")
        }
        let package = try ExtensionPackage.installed(id: extensionID, root: root)
        let suiteName = "XtendMobileViewerQA.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = ExtensionStorage(extensionID: extensionID, defaults: defaults, storageDirectory: directory)
        let host = try ExtensionHost(packages: [package], storageByID: [extensionID: storage])
        let config = WKWebViewConfiguration()
        try host.installBrowserRuntime(into: config)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let view = WKWebView(frame: controller.view.bounds, configuration: config)
        controller.view.addSubview(view)
        host.attach(to: view)
        view.loadHTMLString(html, baseURL: URL(string: "https://x.com/notifications")!)
        return (view, host, window, storage, directory, defaults, suiteName)
    }

    private func script(_ script: String, view: WKWebView) async throws -> String {
        let world = ExtensionPackage.contentWorld(for: extensionID)
        return try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: String(describing: value))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testMobileDrawerExposesOnlyConfirmedViewer() async throws {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body><button data-testid="DashButton_ProfileIcon_Link" aria-expanded="true" style="width:40px;height:40px">Menu</button>
          <div role="dialog" style="position:fixed;top:0;left:0;width:260px;height:100vh;background:white">
            <span>@ringfixture</span><a href="/ringfixture">Account</a><a href="/ringfixture">Profile</a>
          </div>
          <article><a href="/unrelated_user">Unrelated notification author</a></article>
        </body></html>
        """
        let (view, host, window, storage, directory, defaults, suiteName) = try fixture(html: html)
        _ = host
        defer {
            window.isHidden = true
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        var restored: String?
        for _ in 0..<55 {
            restored = try? await script("document.querySelector('a[data-testid=AppTabBar_Profile_Link]')?.getAttribute('href')", view: view)
            if restored == "/ringfixture" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let probe = try await script("JSON.stringify({ready:document.readyState, width:innerWidth, link:!!document.getElementById('xtend-mobile-current-viewer'), dialogs:document.querySelectorAll('[role=dialog]').length, hostname:location.hostname})", view: view)
        XCTAssertEqual(restored, "/ringfixture", probe)
        let saved = try storage.get(area: "local", keys: "xtend:mobile-confirmed-viewer")
        XCTAssertEqual(saved["xtend:mobile-confirmed-viewer"] as? String, "ringfixture")

        // While switching accounts, a mismatched menu must invalidate the
        // previously saved viewer instead of exposing the old profile link.
        _ = try await script("document.querySelector('[role=dialog] span').textContent='@newfixture'; 'changed'", view: view)
        var invalidated = false
        for _ in 0..<55 {
            let link = try? await script("document.querySelector('a[data-testid=AppTabBar_Profile_Link]')?.getAttribute('href')", view: view)
            let stored = try storage.get(area: "local", keys: "xtend:mobile-confirmed-viewer")
            if link != "/ringfixture", stored["xtend:mobile-confirmed-viewer"] == nil {
                invalidated = true
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(invalidated, "The previous account must be invalidated before accepting another")

        // Once both the profile links and the visible account label agree,
        // the new account is allowed and the old one is not reused.
        _ = try await script("document.querySelectorAll('[role=dialog] a').forEach(a=>a.setAttribute('href','/newfixture')); 'changed'", view: view)
        var newViewer: String?
        for _ in 0..<55 {
            newViewer = try? await script("document.querySelector('a[data-testid=AppTabBar_Profile_Link]')?.getAttribute('href')", view: view)
            if newViewer == "/newfixture" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(newViewer, "/newfixture")
        XCTAssertEqual(try storage.get(area: "local", keys: "xtend:mobile-confirmed-viewer")["xtend:mobile-confirmed-viewer"] as? String, "newfixture")
    }

    func testUnverifiedDrawerDoesNotUseNotificationAuthor() async throws {
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body><button data-testid="DashButton_ProfileIcon_Link" aria-expanded="true" style="width:40px;height:40px">Menu</button>
          <div role="dialog" style="position:fixed;top:0;left:0;width:260px;height:100vh;background:white">
            <span>@different_user</span><a href="/ringfixture">Account</a><a href="/ringfixture">Profile</a>
          </div>
          <article><a href="/unrelated_user">Unrelated notification author</a></article>
        </body></html>
        """
        let (view, host, window, storage, directory, defaults, suiteName) = try fixture(html: html)
        _ = host
        defer {
            window.isHidden = true
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<25 {
            if (try? await script("typeof globalThis.chrome?.storage?.local", view: view)) == "object" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await Task.sleep(for: .milliseconds(500))
        let linkVisible = try await script("Boolean(document.querySelector('a[data-testid=AppTabBar_Profile_Link]'))", view: view)
        XCTAssertTrue(["false", "0"].contains(linkVisible), "The viewer link must not be created")
        XCTAssertNil(try storage.get(area: "local", keys: "xtend:mobile-confirmed-viewer")["xtend:mobile-confirmed-viewer"])
    }
}
