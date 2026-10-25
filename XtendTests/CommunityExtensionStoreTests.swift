import XCTest
import ZIPFoundation
@testable import Xtend

final class CommunityExtensionStoreTests: XCTestCase {
    private let fixtureZIP = "UEsDBBQAAAAIAFiNWF07D7rBugAAAAYBAAANAAAAbWFuaWZlc3QuanNvbj2OQWrDQAxFrxK0LMZO6G72IRforgQzkdV4ko7GSHISML57NQ50JelJPP0FcuT0Q2r9g0RTYQifDXDMBAGOr5inX9qdiEkS7r5Gct7A/ykc2n27dzKR5KQVKoRvUCsSrwTnBi4R71cpMw8QFlCSR0Lqn0XuJC54N+1NYW0ACxux9YqSJqumxfMZjrRZR7NJQ9e9Wiy5+6j227YYklqXY+LqcYq6YS9vWmfHMnMfzZ8OBedcH5GnWs/rH1BLAwQUAAAACABYjVhdA4x0jC4AAAA2AAAADAAAAGRpc3QvbWFpbi5qc0vJTy7NTc0r0UuBMlxzUiH8xJLE4tQSvfTUvNSizGTXisTcgpxUW6XK1GIlawBQSwMEFAAAAAgAWI1YXR92Lv8rAAAAKQAAAAwAAABjc3MvbWFpbi5jc3OLTkksSdRNT81LLcpM1k2tSMwtyEmNVahWSMksLshJrLRSyMvPS7VWqAUAUEsDBBQAAAAIAFiNWF2BdhKqHgAAABwAAAAJAAAAd29ya2VyLmpz09dX8MsvUUitSE0uLUlNUcjPUwj3Dk9NCstMLQcAUEsBAhQDFAAAAAgAWI1YXTsPusG6AAAABgEAAA0AAAAAAAAAAAAAAIABAAAAAG1hbmlmZXN0Lmpzb25QSwECFAMUAAAACABYjVhdA4x0jC4AAAA2AAAADAAAAAAAAAAAAAAAgAHlAAAAZGlzdC9tYWluLmpzUEsBAhQDFAAAAAgAWI1YXR92Lv8rAAAAKQAAAAwAAAAAAAAAAAAAAIABPQEAAGNzcy9tYWluLmNzc1BLAQIUAxQAAAAIAFiNWF2BdhKqHgAAABwAAAAJAAAAAAAAAAAAAACAAZIBAAB3b3JrZXIuanNQSwUGAAAAAAQABADmAAAA1wEAAAAA"

    func testGenericZIPInstallUpdateAndRemove() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let zip = base.appendingPathComponent("example.zip")
        try XCTUnwrap(Data(base64Encoded: fixtureZIP)).write(to: zip)
        let store = CommunityExtensionStore(directoryOverride: base.appendingPathComponent("Extensions"))
        let first = try store.installFromZIP(zip)
        XCTAssertTrue(first.id.hasPrefix("zip-"))
        XCTAssertEqual(first.manifest.name, "Example Generic Theme")
        XCTAssertEqual(store.installedRoots().count, 1)
        XCTAssertEqual(try CommunityExtensionStore.validateManifest(at: store.installedRoots()[first.id]!).version, "1.0.0")
        XCTAssertEqual(try store.installFromZIP(zip).id, first.id, "Local ZIP updates retain the same extension identity")
        try store.uninstall(id: first.id)
        XCTAssertTrue(store.installedRoots().isEmpty)
    }

    func testReleaseUpdatePreservesInstalledIdentityAndRejectsDifferentPackage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let zip = base.appendingPathComponent("fixture.zip")
        try XCTUnwrap(Data(base64Encoded: fixtureZIP)).write(to: zip)
        let store = CommunityExtensionStore(directoryOverride: base.appendingPathComponent("Extensions"))
        let installed = try store.installFromZIP(zip)
        let updated = try store.installFromZIP(zip, updatingID: installed.id)
        XCTAssertEqual(updated.id, installed.id)
        XCTAssertEqual(store.installedRoots().count, 1)
        XCTAssertThrowsError(try store.installFromZIP(zip, updatingID: "zip-other-extension"))

        let unpacked = base.appendingPathComponent("unpacked")
        try FileManager.default.unzipItem(at: zip, to: unpacked)
        let manifestURL = unpacked.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["name"] = "Unrelated Extension"
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let maliciousZIP = base.appendingPathComponent("unrelated.zip")
        try FileManager.default.zipItem(at: unpacked, to: maliciousZIP)
        XCTAssertThrowsError(try store.installFromZIP(maliciousZIP, updatingID: installed.id))
        XCTAssertEqual(try CommunityExtensionStore.validateManifest(
            at: XCTUnwrap(store.installedRoots()[installed.id])).name, installed.manifest.name)
        XCTAssertEqual(store.installedRoots().count, 1)
    }

    func testBrokenPackageIsRejectedWithoutReplacingExistingVersion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = CommunityExtensionStore(directoryOverride: base.appendingPathComponent("Extensions"))
        let zip = base.appendingPathComponent("ok.zip")
        try XCTUnwrap(Data(base64Encoded: fixtureZIP)).write(to: zip)
        let good = try store.installFromZIP(zip)
        let invalid = base.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let invalidManifest = #"{"manifest_version":3,"name":"Invalid","version":"1","content_scripts":[{"matches":["https://x.com/*"],"js":["missing.js"]}]}"#
        try invalidManifest.write(to: invalid.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CommunityExtensionStore.validateManifest(at: invalid))
        XCTAssertNotNil(store.installedRoots()[good.id])
    }

    @MainActor
    func testRuntimeLoadsCommunityExtensionWithoutAllowlist() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let zip = base.appendingPathComponent("example.zip")
        try XCTUnwrap(Data(base64Encoded: fixtureZIP)).write(to: zip)
        let store = CommunityExtensionStore(directoryOverride: base.appendingPathComponent("Extensions"))
        _ = try store.installFromZIP(zip)
        let runtime = ExtensionRuntime(installedRoots: store.installedRoots())
        XCTAssertEqual(runtime.packages.count, 1)
        XCTAssertEqual(runtime.packages[0].manifest.name, "Example Generic Theme")
        XCTAssertTrue(runtime.loadIssues.isEmpty)
        XCTAssertNotNil(try runtime.makeBrowserConfiguration().1)
    }
}
