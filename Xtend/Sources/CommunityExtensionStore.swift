import CryptoKit
import Foundation
import ZIPFoundation

/// Shared installer for MV3 packages with X content scripts. No per-extension allowlist.
/// WKWebView runs supported content scripts and CSS, not Chrome service workers.
final class CommunityExtensionStore {
    private let fileManager: FileManager
    private let extensionsDirectory: URL

    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        extensionsDirectory = directoryOverride ?? support.appendingPathComponent("Extensions", isDirectory: true)
        recoverInterruptedInstalls()
    }

    /// Existing legacy packages are managed by their original stores.
    func installedRoots() -> [String: URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: URL] = [:]
        for entry in entries {
            let id = entry.lastPathComponent
            guard id != ExtensionInstallStore.supportedExtensionID,
                  id != ExtensionPackage.homeAnchorID,
                  id != "x-swipe-navigation",
                  isValidID(id),
                  let properties = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true
            else { continue }
            result[id] = entry
        }
        return result
    }

    func installFromZIP(_ url: URL, updatingID: String? = nil) throws -> (id: String, manifest: InstalledExtensionManifest) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try install(data: Data(contentsOf: url, options: [.mappedIfSafe]),
                           storeID: nil, source: .localZIP(url.lastPathComponent), updatingID: updatingID)
    }

    func installFromChromeWebStore(_ url: URL) async throws -> (id: String, manifest: InstalledExtensionManifest) {
        let id = try ExtensionInstallStore.extensionID(from: url)
        let payload = try await ExtensionInstallStore.verifiedDownload(extensionID: id)
        return try installVerifiedWebStoreZIP(payload, storeURL: url)
    }

    func installVerifiedWebStoreZIP(_ payload: Data, storeURL: URL) throws -> (id: String, manifest: InstalledExtensionManifest) {
        let id = try ExtensionInstallStore.extensionID(from: storeURL)
        return try install(data: payload, storeID: id, source: .chromeWebStore(storeURL))
    }

    func uninstall(id: String) throws {
        guard isValidID(id), id != ExtensionInstallStore.supportedExtensionID,
              id != ExtensionPackage.homeAnchorID, id != "x-swipe-navigation" else { throw CommunityExtensionError.invalidIdentity }
        let target = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }

    @discardableResult
    private func install(data: Data, storeID: String?, source: ExtensionInstallSource,
                         updatingID: String? = nil) throws
        -> (id: String, manifest: InstalledExtensionManifest) {
        guard !data.isEmpty else { throw ExtensionInstallError.emptyPackage }
        guard data.count <= ExtensionInstallStore.maximumPackageBytes else {
            throw ExtensionInstallError.packageTooLarge
        }
        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let transaction = extensionsDirectory.appendingPathComponent(".community-import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: transaction) }
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        let archive = transaction.appendingPathComponent("package.zip")
        try data.write(to: archive, options: .atomic)
        try ExtensionInstallStore.validateArchive(at: archive)
        let unpacked = transaction.appendingPathComponent("unpacked")
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archive, to: unpacked)
        let root = try ExtensionInstallStore.findExtensionRoot(in: unpacked, fileManager: fileManager)
        let manifest = try Self.validateManifest(at: root)
        let id: String
        if let updatingID {
            guard isValidID(updatingID),
                  updatingID != ExtensionInstallStore.supportedExtensionID,
                  updatingID != ExtensionPackage.homeAnchorID,
                  updatingID != "x-swipe-navigation",
                  let original = installedRoots()[updatingID],
                  let current = try? Self.validateManifest(at: original),
                  current.name == manifest.name else { throw GitHubReleaseError.unrelatedExtension }
            id = updatingID
        } else if let storeID {
            guard isValidID(storeID), storeID != ExtensionInstallStore.supportedExtensionID,
                  storeID != ExtensionPackage.homeAnchorID, storeID != "x-swipe-navigation" else { throw CommunityExtensionError.invalidIdentity }
            id = storeID
        } else {
            // A ZIP has no CRX signing identity. Name-derived ID stays stable across versions.
            let normalized = manifest.name!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hash = SHA256.hash(data: Data(normalized.utf8))
            id = "zip-" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        }

        let target = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
        let backup = extensionsDirectory.appendingPathComponent(".community-previous-\(id)-\(UUID().uuidString)")
        let hadPrevious = fileManager.fileExists(atPath: target.path)
        do {
            if hadPrevious { try fileManager.moveItem(at: target, to: backup) }
            try fileManager.moveItem(at: root, to: target)
            let metadata = ExtensionInstallMetadata(id: id, version: manifest.version, source: source)
            try JSONEncoder().encode(metadata).write(
                to: target.appendingPathComponent(".xtend-install.json"), options: .atomic)
            if hadPrevious { try? fileManager.removeItem(at: backup) }
        } catch {
            let installError = error
            do {
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                if hadPrevious, fileManager.fileExists(atPath: backup.path) {
                    try fileManager.moveItem(at: backup, to: target)
                }
            } catch {
                throw ExtensionInstallError.rollbackFailed(installError.localizedDescription, error.localizedDescription)
            }
            throw installError
        }
        return (id, manifest)
    }

    static func validateManifest(at root: URL) throws -> InstalledExtensionManifest {
        let manifestFile = try checkedFile("manifest.json", root: root)
        let manifest = try JSONDecoder().decode(InstalledExtensionManifest.self,
                                                from: Data(contentsOf: manifestFile))
        guard manifest.manifestVersion == 3 else {
            throw ExtensionInstallError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        guard let name = manifest.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manifest.version.isEmpty,
              let scripts = manifest.contentScripts, !scripts.isEmpty,
              scripts.contains(where: { script in
                  script.matches.contains("https://x.com/*") || script.matches.contains("https://twitter.com/*")
              }) else { throw CommunityExtensionError.noSupportedContentScript }
        // The legacy Nyatto integration needs privileged assets; never bypass its validation.
        if name == "にゃっとランドforX" || name == "X Swipe Navigation" {
            throw CommunityExtensionError.invalidIdentity
        }
        for script in scripts {
            guard script.world == nil || script.world == "ISOLATED" || script.world == "MAIN",
                  script.runAt == nil || ["document_start", "document_end", "document_idle"].contains(script.runAt!),
                  !script.js.isEmpty || !(script.css ?? []).isEmpty else {
                throw CommunityExtensionError.invalidContentScript
            }
            for path in script.js + (script.css ?? []) {
                let file = try checkedFile(path, root: root)
                guard (try? String(contentsOf: file, encoding: .utf8)) != nil else {
                    throw ExtensionInstallError.missingReferencedFile(path)
                }
            }
        }
        // Background workers and Chrome-only capabilities are not run by Xtend.
        return manifest
    }

    private static func checkedFile(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains(".."), !path.contains("%2f"),
              !path.contains("%2F") else { throw ExtensionInstallError.missingReferencedFile(path) }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let props = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              props.isRegularFile == true, props.isSymbolicLink != true else {
            throw ExtensionInstallError.missingReferencedFile(path)
        }
        return file
    }

    private func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private func recoverInterruptedInstalls() {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: extensionsDirectory.path) else { return }
        // Recovery is intentionally limited to this store's own transaction names.
        for filename in entries where filename.hasPrefix(".community-previous-") {
            let suffix = String(filename.dropFirst(".community-previous-".count))
            guard suffix.count > 37 else { continue }
            let id = String(suffix.dropLast(37)) // hyphen + 36-character UUID
            guard isValidID(id) else { continue }
            let backup = extensionsDirectory.appendingPathComponent(filename)
            let target = extensionsDirectory.appendingPathComponent(id)
            if !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: backup, to: target)
            } else {
                try? fileManager.removeItem(at: backup)
            }
        }
    }
}

enum CommunityExtensionError: LocalizedError {
    case invalidIdentity, noSupportedContentScript, invalidContentScript

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "この拡張機能IDは使用できません。"
        case .noSupportedContentScript: "X向けのcontent_scriptsがないか、Manifest V3の構成が不正です。"
        case .invalidContentScript: "対応していないcontent_scriptsの構成です。"
        }
    }
}
