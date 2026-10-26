import Foundation

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
