import Foundation
import ZIPFoundation

/// Shared URL handling for both the welcome screen and settings.
enum ExtensionURLInstaller {
    @discardableResult
    static func install(_ input: String, githubToken: String?) async throws -> String? {
        if let repository = GitHubReleaseRepository(input: input) {
            return try await GitHubReleaseInstaller.installLatest(repository: repository, newToken: githubToken)
        }
        guard let url = URL(string: input) else { throw GitHubReleaseError.invalidURL }
        if input.contains("github.com") {
            throw GitHubReleaseError.invalidURL
        }
        let extensionID = try ExtensionInstallStore.extensionID(from: url)
        if extensionID == ExtensionInstallStore.supportedExtensionID {
            _ = try await ExtensionInstallStore().installFromChromeWebStore(url)
        } else {
            _ = try await CommunityExtensionStore().installFromChromeWebStore(url)
        }
        return nil
    }
}

/// A signature-verified Web Store package, validated before offering to replace an installed version.
struct CheckedWebStoreUpdate: Sendable {
    let storeURL: URL
    let extensionID: String
    let version: String
    let zipPayload: Data

    func install() throws {
        if extensionID == ExtensionInstallStore.supportedExtensionID {
            _ = try ExtensionInstallStore().installVerifiedWebStoreZIP(zipPayload, storeURL: storeURL)
        } else {
            _ = try CommunityExtensionStore().installVerifiedWebStoreZIP(zipPayload, storeURL: storeURL)
        }
    }
}

extension ExtensionURLInstaller {
    static func checkWebStoreUpdate(_ storeURL: URL) async throws -> CheckedWebStoreUpdate {
        let id = try ExtensionInstallStore.extensionID(from: storeURL)
        let payload = try await ExtensionInstallStore.verifiedDownload(extensionID: id)
        return try inspectWebStorePayload(payload, storeURL: storeURL)
    }

    /// The downloaded CRX must already be signature-verified. Inspect without altering installed files.
    static func inspectWebStorePayload(_ payload: Data, storeURL: URL) throws -> CheckedWebStoreUpdate {
        let id = try ExtensionInstallStore.extensionID(from: storeURL)
        guard !payload.isEmpty, payload.count <= ExtensionInstallStore.maximumPackageBytes else {
            throw ExtensionInstallError.packageTooLarge
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("xtend-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        let archiveURL = temporary.appendingPathComponent("extension.zip")
        try payload.write(to: archiveURL, options: .atomic)
        try ExtensionInstallStore.validateArchive(at: archiveURL)
        let expanded = temporary.appendingPathComponent("expanded", isDirectory: true)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: true)
        try fm.unzipItem(at: archiveURL, to: expanded)
        let root = try ExtensionInstallStore.findExtensionRoot(in: expanded, fileManager: fm)
        let manifest = try id == ExtensionInstallStore.supportedExtensionID
            ? ExtensionInstallStore.readAndValidateManifest(at: root)
            : CommunityExtensionStore.validateManifest(at: root)
        return CheckedWebStoreUpdate(storeURL: storeURL, extensionID: id,
                                     version: manifest.version, zipPayload: payload)
    }
}
