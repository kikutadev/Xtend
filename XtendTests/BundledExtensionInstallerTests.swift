import XCTest
import ZIPFoundation
@testable import Xtend

final class BundledExtensionInstallerTests: XCTestCase {
    func testOptionalZIPIsInstalledOnceAndDoesNotReappearAfterRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtend-seed-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("PreinstalledExtensions")
        let source = root.appendingPathComponent("source")
        let storage = root.appendingPathComponent("Installed")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let manifest = #"{ "manifest_version": 3, "name": "Test Seed Extension", "version": "1.0.0", "content_scripts": [{ "matches": ["https://x.com/*"], "js": ["content.js"] }] }"#
        try manifest.write(to: source.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
        try "console.log('test');".write(to: source.appendingPathComponent("content.js"),
                                           atomically: true, encoding: .utf8)
        try FileManager.default.zipItem(at: source, to: bundled.appendingPathComponent("seed.zip"), shouldKeepParent: false)

        let store = CommunityExtensionStore(directoryOverride: storage)
        let suite = "XtendSeedTest.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        XCTAssertTrue(BundledExtensionInstaller.installIfPresent(
            directory: bundled, store: store, preferences: preferences
        ).isEmpty)
        let installed = try XCTUnwrap(store.installedRoots().first)
        XCTAssertEqual(
            try CommunityExtensionStore.validateManifest(at: installed.value).name,
            "Test Seed Extension"
        )
        XCTAssertTrue(BundledExtensionInstaller.installIfPresent(
            directory: bundled, store: store, preferences: preferences
        ).isEmpty)
        // A manually installed newer version must not be replaced by an older bundle.
        let olderManifest = manifest.replacingOccurrences(of: "1.0.0", with: "0.9.0")
        try olderManifest.write(to: source.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.zipItem(at: source,
                                        to: bundled.appendingPathComponent("older.zip"),
                                        shouldKeepParent: false)
        XCTAssertTrue(BundledExtensionInstaller.installIfPresent(
            directory: bundled, store: store, preferences: preferences
        ).isEmpty)
        XCTAssertEqual(
            try CommunityExtensionStore.validateManifest(at: installed.value).version, "1.0.0"
        )
        try store.uninstall(id: installed.key)
        XCTAssertTrue(BundledExtensionInstaller.installIfPresent(
            directory: bundled, store: store, preferences: preferences
        ).isEmpty)
        XCTAssertTrue(store.installedRoots().isEmpty, "Manually removed extensions stay removed")
    }

    func testMissingBundleDirectoryDoesNothing() {
        XCTAssertTrue(BundledExtensionInstaller.installIfPresent(
            directory: nil, store: CommunityExtensionStore()
        ).isEmpty)
    }
}
