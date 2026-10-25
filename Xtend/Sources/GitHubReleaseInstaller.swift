import Foundation
import Security

/// A repository URL is enough to resolve its latest published (non-prerelease) GitHub Release.
struct GitHubReleaseRepository: Equatable, Sendable {
    let owner: String
    let name: String

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard (path.count == 2 || (path.count == 3 && path[2] == "releases") ||
               (path.count == 4 && path[2] == "releases" && path[3] == "latest") ||
               (path.count == 5 && path[2] == "releases" && path[3] == "tag" && !path[4].isEmpty)),
              Self.valid(path[0]), Self.valid(path[1]) else { return nil }
        owner = path[0]
        name = path[1]
    }

    var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(name)/releases/latest")!
    }

    private static func valid(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value.count <= 100 else { return false }
        return value.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let id: Int
        let name: String
        let size: Int
    }
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", assets
    }

    func extensionZIP() throws -> Asset {
        let zips = assets.filter {
            $0.size > 0 && $0.size <= ExtensionInstallStore.maximumPackageBytes &&
            $0.name.lowercased().hasSuffix(".zip")
        }
        if zips.count == 1 { return zips[0] }
        let chrome = zips.filter {
            let name = $0.name.lowercased()
            return name.contains("chrome") || name.contains("mv3")
        }
        if chrome.count == 1 { return chrome[0] }
        throw GitHubReleaseError.noUniqueExtensionZIP
    }
}

enum GitHubReleaseError: LocalizedError {
    case invalidURL, unavailable, unauthorized, noUniqueExtensionZIP, invalidResponse, unsafeDownload

    var errorDescription: String? {
        switch self {
        case .invalidURL: "GitHubリポジトリのURLを入力してください。"
        case .unavailable: "GitHubの最新Releaseがありません。Privateリポジトリは読み取り用トークンも確認してください。"
        case .unauthorized: "GitHubトークンを確認してください。リポジトリのContentsへの読み取り権限が必要です。"
        case .noUniqueExtensionZIP: "最新Releaseにインストール対象のZIPを1つに特定できません。"
        case .invalidResponse: "GitHubの応答が不正です。"
        case .unsafeDownload: "GitHubから有効なZIPを取得できませんでした。"
        }
    }
}

/// Optional read-only GitHub token for private Releases, stored only on this device.
enum GitHubReleaseCredentials {
    private static let service = "Xtend.GitHubReleases"
    private static let account = "github-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(key as CFDictionary)
        var attributes = key
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw GitHubReleaseError.unauthorized
        }
    }

    static func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

enum GitHubReleaseInstaller {
    /// Resolves the latest version and installs through the existing transactional ZIP validator.
    static func installLatest(repository: GitHubReleaseRepository, newToken: String?) async throws -> String {
        let token = newToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? GitHubReleaseCredentials.load()
        var request = URLRequest(url: repository.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Xtend", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubReleaseError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw GitHubReleaseError.unauthorized
        case 404: throw GitHubReleaseError.unavailable
        default: throw GitHubReleaseError.invalidResponse
        }
        guard responseData.count <= 1_000_000,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: responseData)
        else { throw GitHubReleaseError.invalidResponse }
        let asset = try release.extensionZIP()

        let assetURL = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/releases/assets/\(asset.id)")!
        var assetRequest = URLRequest(url: assetURL)
        assetRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        assetRequest.setValue("Xtend", forHTTPHeaderField: "User-Agent")
        if let token { assetRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let limiter = LimitedPackageDownload(limit: Int64(ExtensionInstallStore.maximumPackageBytes))
        let downloaded: URL
        let downloadResponse: URLResponse
        do {
            (downloaded, downloadResponse) = try await URLSession.shared.download(for: assetRequest, delegate: limiter)
        } catch {
            if limiter.didExceedLimit { throw ExtensionInstallError.packageTooLarge }
            throw error
        }
        guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
              downloadHTTP.statusCode == 200,
              let host = downloadHTTP.url?.host?.lowercased(),
              ["api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github.com"].contains(host),
              let length = (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.intValue,
              length > 0, length <= ExtensionInstallStore.maximumPackageBytes
        else { throw GitHubReleaseError.unsafeDownload }

        let tempZIP = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.copyItem(at: downloaded, to: tempZIP)
        defer { try? FileManager.default.removeItem(at: tempZIP) }
        let prefix = try FileHandle(forReadingFrom: tempZIP)
        defer { try? prefix.close() }
        guard try prefix.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw GitHubReleaseError.unsafeDownload
        }

        // All routes share the same archive/manifest validation and rollback behavior.
        do {
            _ = try XHomeAnchorInstallStore().installFromZIP(tempZIP)
        } catch XHomeAnchorInstallError.unsupportedPackage {
            do {
                _ = try ExtensionInstallStore().installFromZIP(tempZIP)
            } catch ExtensionInstallError.missingRequiredCapability {
                _ = try CommunityExtensionStore().installFromZIP(tempZIP)
            }
        }
        if let newToken = newToken?.trimmingCharacters(in: .whitespacesAndNewlines), !newToken.isEmpty {
            try GitHubReleaseCredentials.save(newToken)
        }
        return release.tagName
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
