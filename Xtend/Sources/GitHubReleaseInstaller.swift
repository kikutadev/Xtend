import Foundation
import Security

/// A repository URL is enough to resolve its latest published (non-prerelease) GitHub Release.
struct GitHubReleaseRepository: Equatable, Sendable {
    let owner: String
    let name: String

    init?(url: URL) { self.init(input: url.absoluteString) }

    /// Accept GitHub HTTPS, HTTPS clone (.git), scp-style SSH and ssh:// clone URLs.
    init?(input: String) {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if raw.hasPrefix("git@github.com:") {
            text = "https://github.com/" + raw.dropFirst("git@github.com:".count)
        } else if raw.hasPrefix("ssh://git@github.com/") {
            text = "https://github.com/" + raw.dropFirst("ssh://git@github.com/".count)
        } else {
            text = raw
        }
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "github.com",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        guard !path.isEmpty else { return nil }
        let repoName = path.count > 1 && path[1].hasSuffix(".git")
            ? String(path[1].dropLast(4)) : (path.count > 1 ? path[1] : "")
        guard (path.count == 2 || (path.count == 3 && path[2] == "releases") ||
               (path.count == 4 && path[2] == "releases" && path[3] == "latest") ||
               (path.count == 5 && path[2] == "releases" && path[3] == "tag" && !path[4].isEmpty)),
              Self.valid(path[0]), Self.valid(repoName) else { return nil }
        owner = path[0]
        name = repoName
    }

    var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

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
    case invalidURL, unavailable, unauthorized, noUniqueExtensionZIP, invalidResponse, unsafeDownload, unrelatedExtension

    var errorDescription: String? {
        switch self {
        case .invalidURL: "GitHubリポジトリのURLを入力してください。"
        case .unavailable: "GitHubの最新Releaseがありません。Privateリポジトリは読み取り用トークンも確認してください。"
        case .unauthorized: "GitHubトークンを確認してください。リポジトリのContentsへの読み取り権限が必要です。"
        case .noUniqueExtensionZIP: "最新Releaseにインストール対象のZIPを1つに特定できません。"
        case .invalidResponse: "GitHubの応答が不正です。"
        case .unsafeDownload: "GitHubから有効なZIPを取得できませんでした。"
        case .unrelatedExtension: "Release内の拡張機能がインストール済みのものと異なります。"
        }
    }
}

/// Optional read-only GitHub token for private Releases, stored only on this device.
enum GitHubReleaseCredentials {
    static let defaultService = "Xtend.GitHubReleases"
    private static let account = "github-token"

    static func load(service: String = defaultService) -> String? {
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

    static func save(_ token: String, service: String = defaultService) throws {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Updating in place avoids deleting a previously valid token if a
        // subsequent Keychain write fails.
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(key as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GitHubReleaseError.unauthorized }
        var attributes = key
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw GitHubReleaseError.unauthorized
        }
    }

    static func remove(service: String = defaultService) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

struct GitHubReleaseLink: Codable {
    let repository: String
    let installedTag: String?
}

enum GitHubReleaseLinks {
    private static func key(_ id: String) -> String { "xtend.extension.github.\(id)" }

    static func get(_ id: String) -> GitHubReleaseLink? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(GitHubReleaseLink.self, from: data)
    }

    static func save(id: String, repository: GitHubReleaseRepository, tag: String?) {
        let value = GitHubReleaseLink(repository: repository.webURL.absoluteString, installedTag: tag)
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
    }

    static func remove(_ id: String) { UserDefaults.standard.removeObject(forKey: key(id)) }
}

/// Comparison uses the tag recorded at install when available, otherwise numeric versions.
/// If version formats cannot be compared, offer a manual update instead of declaring current.
enum GitHubReleaseVersion {
    static func needsUpdate(installed: String, latestTag: String, installedTag: String?) -> Bool {
        if installedTag == latestTag { return false }
        func components(_ raw: String) -> [Int]? {
            let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            guard !text.isEmpty,
                  text.allSatisfy({ $0.isNumber || $0 == "." }),
                  !text.hasSuffix("."),
                  !text.contains("..") else { return nil }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = parts.compactMap { Int($0) }
            return numbers.count == parts.count ? numbers : nil
        }
        guard let current = components(installed), let available = components(latestTag) else {
            return installedTag.map { $0 != latestTag } ?? (installed != latestTag)
        }
        for (a, b) in zip(current, available) where a != b { return b > a }
        return available.count > current.count && available.dropFirst(current.count).contains(where: { $0 > 0 })
    }
}

struct GitHubReleaseCheck: Sendable {
    let release: GitHubRelease
    let needsUpdate: Bool
}

enum GitHubReleaseInstaller {
    static func check(repository: GitHubReleaseRepository, installedVersion: String,
                      installedTag: String?, tokenOverride: String? = nil,
                      session: URLSession = .shared,
                      credentialsService: String = GitHubReleaseCredentials.defaultService) async throws -> GitHubReleaseCheck {
        let token = tokenOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? GitHubReleaseCredentials.load(service: credentialsService)
        let release = try await fetchLatest(repository: repository, token: token, session: session)
        return GitHubReleaseCheck(release: release,
            needsUpdate: GitHubReleaseVersion.needsUpdate(installed: installedVersion,
                latestTag: release.tagName, installedTag: installedTag))
    }

    private static func fetchLatest(repository: GitHubReleaseRepository, token: String?,
                                    session: URLSession) async throws -> GitHubRelease {
        var request = URLRequest(url: repository.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Xtend", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host?.lowercased() == "api.github.com"
        else { throw GitHubReleaseError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw GitHubReleaseError.unauthorized
        case 404: throw GitHubReleaseError.unavailable
        default: throw GitHubReleaseError.invalidResponse
        }
        guard responseData.count <= 1_000_000,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: responseData)
        else { throw GitHubReleaseError.invalidResponse }
        _ = try release.extensionZIP()
        return release
    }

    /// Resolves the newest Release and safely updates an existing extension when specified.
    @discardableResult
    static func installLatest(repository: GitHubReleaseRepository, newToken: String?,
                              existingID: String? = nil, session: URLSession = .shared,
                              credentialsService: String = GitHubReleaseCredentials.defaultService) async throws -> String {
        let token = newToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? GitHubReleaseCredentials.load(service: credentialsService)
        let release = try await fetchLatest(repository: repository, token: token, session: session)
        let asset = try release.extensionZIP()

        let assetURL = URL(string: "https://api.github.com/repos/\(repository.owner)/\(repository.name)/releases/assets/\(asset.id)")!
        var assetRequest = URLRequest(url: assetURL)
        assetRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        assetRequest.setValue("Xtend", forHTTPHeaderField: "User-Agent")
        if let token { assetRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let allowedHosts: Set<String> = ["api.github.com", "release-assets.githubusercontent.com",
                                          "objects.githubusercontent.com", "github.com"]
        let limiter = LimitedPackageDownload(limit: Int64(ExtensionInstallStore.maximumPackageBytes),
                                             allowedRedirectHosts: allowedHosts)
        let downloaded: URL
        let downloadResponse: URLResponse
        do {
            (downloaded, downloadResponse) = try await session.download(for: assetRequest, delegate: limiter)
        } catch {
            if limiter.didExceedLimit { throw ExtensionInstallError.packageTooLarge }
            throw error
        }
        guard let downloadHTTP = downloadResponse as? HTTPURLResponse,
              downloadHTTP.statusCode == 200, downloadHTTP.url?.scheme == "https",
              let host = downloadHTTP.url?.host?.lowercased(),
              allowedHosts.contains(host),
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

        // Installed IDs must remain stable. The generic installer validates the original name
        // before replacing its files, and the special stores keep their fixed identities.
        let installedID: String
        if let existingID {
            switch existingID {
            case ExtensionInstallStore.supportedExtensionID:
                _ = try ExtensionInstallStore().installFromZIP(tempZIP)
                installedID = existingID
            case ExtensionPackage.homeAnchorID:
                _ = try XHomeAnchorInstallStore().installFromZIP(tempZIP)
                installedID = existingID
            default:
                let result = try CommunityExtensionStore().installFromZIP(tempZIP, updatingID: existingID)
                installedID = result.id
            }
        } else {
            do {
                _ = try XHomeAnchorInstallStore().installFromZIP(tempZIP)
                installedID = ExtensionPackage.homeAnchorID
            } catch XHomeAnchorInstallError.unsupportedPackage {
                do {
                    _ = try ExtensionInstallStore().installFromZIP(tempZIP)
                    installedID = ExtensionInstallStore.supportedExtensionID
                } catch ExtensionInstallError.missingRequiredCapability {
                    let result = try CommunityExtensionStore().installFromZIP(tempZIP)
                    installedID = result.id
                }
            }
        }
        GitHubReleaseLinks.save(id: installedID, repository: repository, tag: release.tagName)
        if let newToken = newToken?.trimmingCharacters(in: .whitespacesAndNewlines), !newToken.isEmpty {
            try GitHubReleaseCredentials.save(newToken, service: credentialsService)
        }
        return release.tagName
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
