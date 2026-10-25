import Foundation
import ZIPFoundation

/// Cancels the transfer as soon as the CRX download exceeds the limit.
final class LimitedPackageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let lock = NSLock()
    private var exceeded = false

    init(limit: Int64) { self.limit = limit }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > limit || totalBytesExpectedToWrite > limit else { return }
        lock.lock()
        exceeded = true
        lock.unlock()
        downloadTask.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// Installs the one Chrome Web Store extension supported by this app.
///
/// The app intentionally does not expose a general-purpose extension runtime.
/// Both the Web Store path and local ZIP path converge on the same validated,
/// unpacked extension directory under Application Support.
final class ExtensionInstallStore {
    static let supportedExtensionID = "kchlmbffcbaambfigakeiamkhgacemng"
    static let defaultStoreURL = URL(
        string: "https://chromewebstore.google.com/detail/%E3%81%AB%E3%82%83%E3%81%A3%E3%81%A8%E3%83%A9%E3%83%B3%E3%83%89forx/kchlmbffcbaambfigakeiamkhgacemng"
    )!

    static let maximumPackageBytes = 64 * 1024 * 1024
    private static let maximumExpandedBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumArchiveEntries = 10_000

    private let fileManager: FileManager
    private let extensionsDirectory: URL
    private(set) var recoveryIssue: String?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.extensionsDirectory = applicationSupport.appendingPathComponent("Extensions", isDirectory: true)
        do {
            try Self.recoverInterruptedReplacement(
                directory: extensionsDirectory, name: Self.supportedExtensionID,
                backupPrefix: ".previous-", fileManager: fileManager
            )
        } catch {
            recoveryIssue = error.localizedDescription
        }
    }

    static func recoverInterruptedReplacement(
        directory: URL, name: String, backupPrefix: String, fileManager: FileManager
    ) throws {
        let destination = directory.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.fileExists(atPath: directory.path) else { return }
        let backups = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
        guard let newest = backups.max(by: {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }) else { return }
        try fileManager.moveItem(at: newest, to: destination)
    }

    static func discardBackups(directory: URL, prefix: String, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for item in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: []) {
            if item.lastPathComponent.hasPrefix(prefix) {
                try fileManager.removeItem(at: item)
            }
        }
    }

    var existingRoot: URL? {
        let root = extensionsDirectory.appendingPathComponent(Self.supportedExtensionID, isDirectory: true)
        return fileManager.fileExists(atPath: root.path) ? root : nil
    }

    var installedExtensionRoot: URL? {
        guard let root = existingRoot else { return nil }
        return fileManager.fileExists(atPath: root.appendingPathComponent("manifest.json").path) ? root : nil
    }

    func installedManifest() throws -> InstalledExtensionManifest? {
        guard let root = installedExtensionRoot else { return nil }
        return try Self.readAndValidateManifest(at: root)
    }

    /// Downloads the CRX3 package through Chrome Web Store's update service,
    /// strips the CRX envelope, then installs the ZIP payload.
    func installFromChromeWebStore(_ storeURL: URL) async throws -> InstalledExtensionManifest {
        let extensionID = try Self.extensionID(from: storeURL)
        guard extensionID == Self.supportedExtensionID else {
            throw ExtensionInstallError.unsupportedExtension(extensionID)
        }

        let zipPayload = try await Self.verifiedDownload(extensionID: extensionID)
        return try installZIPData(
            zipPayload,
            expectedExtensionID: extensionID,
            source: .chromeWebStore(storeURL)
        )
    }

    static func verifiedDownload(extensionID: String) async throws -> Data {
        let downloadURL = try Self.chromeWebStoreDownloadURL(extensionID: extensionID)
        // Stream to disk and cancel oversized CRX transfers before they complete.
        let limiter = LimitedPackageDownload(limit: Int64(Self.maximumPackageBytes + (1 << 18)))
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await URLSession.shared.download(
                for: URLRequest(url: downloadURL), delegate: limiter
            )
        } catch {
            if limiter.didExceedLimit { throw ExtensionInstallError.packageTooLarge }
            throw error
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              Self.isTrustedChromePackageURL(finalURL) else {
            throw ExtensionInstallError.untrustedDownloadResponse
        }

        let byteCount = (try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, byteCount <= Self.maximumPackageBytes + (1 << 18) else {
            throw ExtensionInstallError.packageTooLarge
        }
        let crxData = try Data(contentsOf: temporaryURL, options: [.mappedIfSafe])
        return try CRX3Package.verifiedZIPPayload(from: crxData, expectedExtensionID: extensionID)
    }

    /// Imports a source ZIP selected by the user. Local ZIPs are intentionally
    /// restricted to the known extension contract rather than becoming an
    /// arbitrary-code plug-in mechanism.
    func installFromZIP(_ zipURL: URL) throws -> InstalledExtensionManifest {
        let didAccess = zipURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { zipURL.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: zipURL, options: [.mappedIfSafe])
        return try installZIPData(
            data,
            expectedExtensionID: Self.supportedExtensionID,
            source: .localZIP(zipURL.lastPathComponent)
        )
    }

    func uninstall() throws {
        if let root = existingRoot { try fileManager.removeItem(at: root) }
        try Self.discardBackups(directory: extensionsDirectory, prefix: ".previous-", fileManager: fileManager)
    }

    private func installZIPData(
        _ data: Data,
        expectedExtensionID: String,
        source: ExtensionInstallSource
    ) throws -> InstalledExtensionManifest {
        guard !data.isEmpty else { throw ExtensionInstallError.emptyPackage }
        guard data.count <= Self.maximumPackageBytes else {
            throw ExtensionInstallError.packageTooLarge
        }

        try fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)

        let transactionRoot = extensionsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = transactionRoot.appendingPathComponent("extension.zip")
        let unpackedURL = transactionRoot.appendingPathComponent("unpacked", isDirectory: true)
        defer { try? fileManager.removeItem(at: transactionRoot) }

        try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
        try data.write(to: archiveURL, options: [.atomic])
        try Self.validateArchive(at: archiveURL)
        try fileManager.createDirectory(at: unpackedURL, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archiveURL, to: unpackedURL)

        let extensionRoot = try Self.findExtensionRoot(in: unpackedURL, fileManager: fileManager)
        let manifest = try Self.readAndValidateManifest(at: extensionRoot)

        // Local source ZIPs do not carry the CRX public-key identity. The app is
        // intentionally single-extension, so the validated contract is installed
        // under the one allow-listed extension ID.
        guard expectedExtensionID == Self.supportedExtensionID else {
            throw ExtensionInstallError.unsupportedExtension(expectedExtensionID)
        }

        let destination = extensionsDirectory.appendingPathComponent(expectedExtensionID, isDirectory: true)
        let previous = extensionsDirectory.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)

        do {
            if hadPrevious {
                try fileManager.moveItem(at: destination, to: previous)
            }
            try fileManager.moveItem(at: extensionRoot, to: destination)
            try Self.writeInstallMetadata(
                ExtensionInstallMetadata(id: expectedExtensionID, version: manifest.version, source: source),
                to: destination
            )
            if hadPrevious { try? fileManager.removeItem(at: previous) }
        } catch {
            let installationError = error
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                if hadPrevious, fileManager.fileExists(atPath: previous.path) {
                    try fileManager.moveItem(at: previous, to: destination)
                }
            } catch {
                // Keep the .previous directory for manual recovery.
                throw ExtensionInstallError.rollbackFailed(installationError.localizedDescription, error.localizedDescription)
            }
            throw installationError
        }

        return manifest
    }

    static func extensionID(from storeURL: URL) throws -> String {
        let rawID = storeURL.scheme == nil && storeURL.absoluteString.count == 32
        guard rawID || (storeURL.scheme == "https" &&
                        storeURL.host?.lowercased() == "chromewebstore.google.com") else {
            throw ExtensionInstallError.invalidChromeWebStoreURL
        }
        let candidate = rawID
            ? storeURL.absoluteString
            : storeURL.pathComponents.last(where: { $0.count == 32 })
        guard let candidate,
              candidate.count == 32,
              candidate.allSatisfy({ ("a"..."p").contains(String($0)) }) else {
            throw ExtensionInstallError.invalidChromeWebStoreURL
        }
        return candidate
    }

    private static func chromeWebStoreDownloadURL(extensionID: String) throws -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "140.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(extensionID)&uc")
        ]
        guard let url = components.url else { throw ExtensionInstallError.invalidChromeWebStoreURL }
        return url
    }

    private static func isTrustedChromePackageURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "clients2.google.com" || host == "clients2.googleusercontent.com"
    }

    static func validateArchive(at archiveURL: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw ExtensionInstallError.invalidZIPArchive
        }

        var entryCount = 0
        var expandedBytes: UInt64 = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumArchiveEntries else {
                throw ExtensionInstallError.archiveEntryLimitExceeded
            }

            let normalizedPath = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalizedPath.hasPrefix("/"),
                  !normalizedPath.hasPrefix("~"),
                  !components.contains(where: { $0 == ".." }),
                  !components.contains(where: { $0.isEmpty && $0 != components.last }) else {
                throw ExtensionInstallError.unsafeArchivePath(entry.path)
            }

            guard entry.type != .symlink else {
                throw ExtensionInstallError.symbolicLinkNotAllowed(entry.path)
            }

            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= maximumExpandedBytes else {
                throw ExtensionInstallError.expandedPackageTooLarge
            }
            expandedBytes = sum
        }

        guard entryCount > 0 else { throw ExtensionInstallError.emptyPackage }
    }

    static func findExtensionRoot(in unpackedURL: URL, fileManager: FileManager) throws -> URL {
        let directManifest = unpackedURL.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: directManifest.path) { return unpackedURL }

        let children = try fileManager.contentsOfDirectory(
            at: unpackedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
        guard candidates.count == 1, let root = candidates.first else {
            throw ExtensionInstallError.manifestNotFound
        }
        return root
    }

    static func readAndValidateManifest(at root: URL) throws -> InstalledExtensionManifest {
        let manifestURL = root.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(InstalledExtensionManifest.self, from: data)

        guard manifest.manifestVersion == 3 else {
            throw ExtensionInstallError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        guard manifest.permissions?.contains("storage") == true else {
            throw ExtensionInstallError.missingRequiredCapability("storage")
        }
        guard let scripts = manifest.contentScripts, scripts.count >= 2 else {
            throw ExtensionInstallError.missingRequiredCapability("content_scripts")
        }

        let allJS = scripts.flatMap(\.js)
        for required in ["inject.js", "xff-asset-loader.js", "content.js"] where !allJS.contains(required) {
            throw ExtensionInstallError.missingRequiredCapability(required)
        }
        guard scripts.flatMap(\.matches).contains(where: {
            $0 == "https://x.com/*" || $0 == "https://twitter.com/*"
        }) else {
            throw ExtensionInstallError.missingRequiredCapability("x.com host match")
        }

        // The WebKit runtime always loads these Nyatto resources, even if
        // the manifest itself does not explicitly reference them.
        let referencedFiles = scripts.flatMap(\.js)
            + scripts.flatMap { $0.css ?? [] }
            + [manifest.background?.serviceWorker].compactMap { $0 }
            + ["popup.html", "xff-assets.js"]
        for relativePath in referencedFiles {
            guard let file = safeExistingFile(relativePath, under: root),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))?.isRegularFile == true else {
                throw ExtensionInstallError.missingReferencedFile(relativePath)
            }
            if relativePath.hasSuffix(".js") || relativePath.hasSuffix(".css") {
                guard (try? String(contentsOf: file, encoding: .utf8)) != nil else {
                    throw ExtensionInstallError.missingReferencedFile(relativePath)
                }
            }
        }
        _ = try PackedAssetStore(root: root)
        return manifest
    }

    private static func safeExistingFile(_ relativePath: String, under root: URL) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else { return nil }
        let standardizedRoot = root.standardizedFileURL
        let file = root.appendingPathComponent(relativePath).standardizedFileURL
        guard file.path.hasPrefix(standardizedRoot.path + "/"),
              FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return file
    }

    private static func writeInstallMetadata(_ metadata: ExtensionInstallMetadata, to root: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: root.appendingPathComponent(".xtend-install.json"), options: [.atomic])
    }
}

struct InstalledExtensionManifest: Decodable, Sendable {
    let manifestVersion: Int
    let name: String?
    let defaultLocale: String?
    let icons: [String: String]?
    let version: String
    let versionName: String?
    let permissions: [String]?
    let contentScripts: [ContentScript]?
    let background: Background?
    let action: Action?
    let optionsUI: OptionsUI?
    let optionsPage: String?

    struct Action: Decodable, Sendable {
        let defaultPopup: String?
        enum CodingKeys: String, CodingKey { case defaultPopup = "default_popup" }
    }

    struct OptionsUI: Decodable, Sendable {
        let page: String
        let openInTab: Bool?
        enum CodingKeys: String, CodingKey { case page; case openInTab = "open_in_tab" }
    }

    struct ContentScript: Decodable, Sendable {
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

    struct Background: Decodable, Sendable {
        let serviceWorker: String?

        enum CodingKeys: String, CodingKey {
            case serviceWorker = "service_worker"
        }
    }

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name, icons
        case defaultLocale = "default_locale"
        case version
        case versionName = "version_name"
        case permissions
        case contentScripts = "content_scripts"
        case background, action
        case optionsUI = "options_ui"
        case optionsPage = "options_page"
    }
}

enum ExtensionInstallSource: Codable, Sendable {
    case chromeWebStore(URL)
    case localZIP(String)
}

struct ExtensionInstallMetadata: Codable, Sendable {
    let id: String
    let version: String
    let source: ExtensionInstallSource
    let installedAt: Date

    init(id: String, version: String, source: ExtensionInstallSource) {
        self.id = id
        self.version = version
        self.source = source
        self.installedAt = Date()
    }
}

enum ExtensionInstallError: LocalizedError {
    case invalidChromeWebStoreURL
    case unsupportedExtension(String)
    case untrustedDownloadResponse
    case emptyPackage
    case manifestNotFound
    case unsupportedManifestVersion(Int)
    case missingRequiredCapability(String)
    case missingReferencedFile(String)
    case packageTooLarge
    case invalidZIPArchive
    case archiveEntryLimitExceeded
    case expandedPackageTooLarge
    case unsafeArchivePath(String)
    case symbolicLinkNotAllowed(String)
    case rollbackFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidChromeWebStoreURL:
            "Chrome Web Store URLから拡張機能IDを取得できませんでした。"
        case .unsupportedExtension(let id):
            "このビルドでは拡張機能 \(id) は許可されていません。"
        case .untrustedDownloadResponse:
            "Chrome Web Storeの信頼済み配信先からCRXを取得できませんでした。"
        case .emptyPackage:
            "拡張機能パッケージが空です。"
        case .manifestNotFound:
            "ZIP内にmanifest.jsonが見つかりません。"
        case .unsupportedManifestVersion(let version):
            "Manifest V\(version) はこのランタイムではサポートしていません。"
        case .missingRequiredCapability(let capability):
            "にゃっとランドforXに必要な構成がありません: \(capability)"
        case .missingReferencedFile(let file):
            "manifestが参照しているファイルがありません: \(file)"
        case .packageTooLarge:
            "拡張機能パッケージが大きすぎます。"
        case .invalidZIPArchive:
            "有効なZIPアーカイブとして読み込めませんでした。"
        case .archiveEntryLimitExceeded:
            "ZIP内のファイル数が上限を超えています。"
        case .expandedPackageTooLarge:
            "ZIPの展開後サイズが上限を超えています。"
        case .unsafeArchivePath(let path):
            "ZIP内に安全でないパスがあります: \(path)"
        case .symbolicLinkNotAllowed(let path):
            "ZIP内のシンボリックリンクは許可されていません: \(path)"
        case .rollbackFailed(let install, let recovery):
            "更新に失敗し、旧版の復元にも失敗しました（更新: \(install)、復元: \(recovery)）。修復が必要です。"
        }
    }
}