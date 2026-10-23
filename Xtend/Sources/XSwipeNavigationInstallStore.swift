import Foundation
import ZIPFoundation

/// Installs only the supported, prebuilt X Swipe Navigation WXT package.
/// All persistent files remain separate from Nyatto and x-home-anchor.
final class XSwipeNavigationInstallStore {
    static let extensionDirectoryName = "x-swipe-navigation"
    private let fileManager: FileManager
    private let extensionsDirectory: URL
    private(set) var recoveryIssue: String?

    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        extensionsDirectory = directoryOverride ?? support.appendingPathComponent("Extensions", isDirectory: true)
        do {
            try ExtensionInstallStore.recoverInterruptedReplacement(
                directory: extensionsDirectory, name: Self.extensionDirectoryName,
                backupPrefix: ".swipe-previous-", fileManager: fileManager
            )
        } catch {
            recoveryIssue = error.localizedDescription
        }
    }

    var existingRoot: URL? {
        let root = extensionsDirectory.appendingPathComponent(Self.extensionDirectoryName, isDirectory: true)
        return fileManager.fileExists(atPath: root.path) ? root : nil
    }

    func uninstall() throws {
        if let root = existingRoot { try fileManager.removeItem(at: root) }
        try ExtensionInstallStore.discardBackups(
            directory: extensionsDirectory, prefix: ".swipe-previous-", fileManager: fileManager
        )
    }

    @discardableResult
    func installFromZIP(_ zipURL: URL) throws -> String {
        let access = zipURL.startAccessingSecurityScopedResource()
        defer { if access { zipURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: zipURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw ExtensionInstallError.emptyPackage }
        guard data.count <= ExtensionInstallStore.maximumPackageBytes else {
            throw ExtensionInstallError.packageTooLarge
        }

        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let transaction = extensionsDirectory.appendingPathComponent(
            ".swipe-import-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fileManager.removeItem(at: transaction) }
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        let archiveURL = transaction.appendingPathComponent("package.zip")
        try data.write(to: archiveURL, options: .atomic)
        try ExtensionInstallStore.validateArchive(at: archiveURL)
        let unpacked = transaction.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archiveURL, to: unpacked)
        let root = try ExtensionInstallStore.findExtensionRoot(in: unpacked, fileManager: fileManager)
        let version = try Self.validateManifest(at: root)

        let target = extensionsDirectory.appendingPathComponent(Self.extensionDirectoryName, isDirectory: true)
        let previous = extensionsDirectory.appendingPathComponent(".swipe-previous-\(UUID().uuidString)", isDirectory: true)
        let hasPrevious = fileManager.fileExists(atPath: target.path)
        do {
            if hasPrevious { try fileManager.moveItem(at: target, to: previous) }
            try fileManager.moveItem(at: root, to: target)
            if hasPrevious { try? fileManager.removeItem(at: previous) }
        } catch {
            let installationError = error
            do {
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                if hasPrevious, fileManager.fileExists(atPath: previous.path) {
                    try fileManager.moveItem(at: previous, to: target)
                }
            } catch {
                throw ExtensionInstallError.rollbackFailed(
                    installationError.localizedDescription, error.localizedDescription
                )
            }
            throw installationError
        }
        return version
    }

    static func validateManifest(at root: URL) throws -> String {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(InstalledExtensionManifest.self, from: data),
              manifest.manifestVersion == 3,
              manifest.name == "X Swipe Navigation",
              !manifest.version.isEmpty,
              (manifest.permissions ?? []).isEmpty,
              manifest.background == nil,
              manifest.contentScripts?.count == 1,
              let script = manifest.contentScripts?.first,
              Set(script.matches) == Set(["https://x.com/*", "https://twitter.com/*"]),
              script.matches.count == 2,
              script.js == ["content-scripts/content.js"],
              (script.css ?? []).isEmpty,
              script.world == nil || script.world == "ISOLATED",
              script.runAt == "document_idle" else {
            throw XSwipeNavigationInstallError.unsupportedPackage
        }
        let scriptURL = root.appendingPathComponent("content-scripts/content.js").standardizedFileURL
        let values = try? scriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard scriptURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw XSwipeNavigationInstallError.missingBuiltScript
        }
        return manifest.version
    }
}

enum XSwipeNavigationInstallError: LocalizedError {
    case unsupportedPackage
    case missingBuiltScript

    var errorDescription: String? {
        switch self {
        case .unsupportedPackage:
            "X Swipe Navigationのビルド済みZIPではありません。"
        case .missingBuiltScript:
            "content-scripts/content.jsがありません。WXTでビルドしたZIPを選択してください。"
        }
    }
}