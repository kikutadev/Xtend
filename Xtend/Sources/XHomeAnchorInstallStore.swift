import Foundation
import ZIPFoundation

/// Adds the supported X Home Anchor source ZIP without replacing Nyatto.
@MainActor
final class XHomeAnchorInstallStore {
    static let extensionDirectoryName = "x-home-anchor"
    private let fileManager: FileManager
    private let extensionsDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        extensionsDirectory = support.appendingPathComponent("Extensions", isDirectory: true)
    }

    var installedRoot: URL? {
        let root = extensionsDirectory.appendingPathComponent(Self.extensionDirectoryName, isDirectory: true)
        return (try? Self.validateManifest(at: root)) != nil ? root : nil
    }

    func uninstall() throws {
        guard let root = installedRoot else { return }
        try fileManager.removeItem(at: root)
    }

    @discardableResult
    func installFromZIP(_ zipURL: URL) throws -> String {
        let securityAccess = zipURL.startAccessingSecurityScopedResource()
        defer { if securityAccess { zipURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: zipURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { throw ExtensionInstallError.emptyPackage }
        guard data.count <= ExtensionInstallStore.maximumPackageBytes else {
            throw ExtensionInstallError.packageTooLarge
        }

        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let transaction = extensionsDirectory.appendingPathComponent(".anchor-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: transaction) }
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)

        let archiveURL = transaction.appendingPathComponent("source.zip")
        try data.write(to: archiveURL, options: .atomic)
        try ExtensionInstallStore.validateArchive(at: archiveURL)
        let unpacked = transaction.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archiveURL, to: unpacked)
        let root = try ExtensionInstallStore.findExtensionRoot(in: unpacked, fileManager: fileManager)
        let version = try Self.validateManifest(at: root)

        let target = extensionsDirectory.appendingPathComponent(Self.extensionDirectoryName, isDirectory: true)
        let previous = extensionsDirectory.appendingPathComponent(".anchor-previous-\(UUID().uuidString)", isDirectory: true)
        let hasPrevious = fileManager.fileExists(atPath: target.path)
        do {
            if hasPrevious { try fileManager.moveItem(at: target, to: previous) }
            try fileManager.moveItem(at: root, to: target)
            if hasPrevious { try? fileManager.removeItem(at: previous) }
        } catch {
            try? fileManager.removeItem(at: target)
            if hasPrevious { try? fileManager.moveItem(at: previous, to: target) }
            throw error
        }
        return version
    }

    static func validateManifest(at root: URL) throws -> String {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(AnchorManifest.self, from: data),
              manifest.manifestVersion == 3,
              manifest.name == "X ホームの閲覧位置",
              !manifest.version.isEmpty,
              manifest.contentScripts.count == 1,
              let script = manifest.contentScripts.first,
              script.matches == ["https://x.com/*"],
              script.js == ["content.js"],
              (script.css ?? []).isEmpty,
              script.world == nil || script.world == "ISOLATED",
              script.runAt == "document_idle" else {
            throw XHomeAnchorInstallError.unsupportedPackage
        }

        // The GitHub source archive contains TypeScript and cannot run as a
        // browser extension until npm run build has produced dist/content.js.
        let sourceURL = root.appendingPathComponent("content.js").standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        guard sourceURL.path.hasPrefix(standardizedRoot.path + "/"),
              fileManagerIsRegularFile(sourceURL) else {
            throw XHomeAnchorInstallError.missingBuiltContentScript
        }
        return manifest.version
    }

    private static func fileManagerIsRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private struct AnchorManifest: Decodable {
        let manifestVersion: Int
        let name: String
        let version: String
        let contentScripts: [Script]

        struct Script: Decodable {
            let matches: [String]
            let js: [String]
            let css: [String]?
            let world: String?
            let runAt: String?
            enum CodingKeys: String, CodingKey {
                case matches, js, css, world
                case runAt = "run_at"
            }
        }

        enum CodingKeys: String, CodingKey {
            case manifestVersion = "manifest_version"
            case name, version
            case contentScripts = "content_scripts"
        }
    }
}

enum XHomeAnchorInstallError: LocalizedError {
    case unsupportedPackage
    case missingBuiltContentScript

    var errorDescription: String? {
        switch self {
        case .unsupportedPackage:
            "X ホームの閲覧位置の拡張機能ZIPではありません。ビルド済みdistフォルダをZIPにしてください。"
        case .missingBuiltContentScript:
            "content.jsがありません。GitHubのソースをnpm run buildでビルドし、distフォルダをZIPにしてください。"
        }
    }
}
