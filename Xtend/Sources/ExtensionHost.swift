import Foundation
import WebKit

/// WebKit 上で利用する、検証済みの拡張機能パッケージ。
struct ExtensionPackage {
    static let homeAnchorID = "x-home-anchor"

    let id: String
    let root: URL
    let manifest: InstalledExtensionManifest

    @MainActor
    static func contentWorld(for id: String) -> WKContentWorld {
        WKContentWorld.world(name: "Xtend.Extension.\(id)")
    }

    struct SettingsPage {
        let path: String
        let prefersWideLayout: Bool
    }

    /// Read the declared popup/options page without executing arbitrary paths.
    /// A missing or unsafe page is treated as unavailable, not a broken content script.
    var settingsPage: SettingsPage? {
        let options = manifest.optionsUI?.page ?? manifest.optionsPage
        let popup = manifest.action?.defaultPopup
        var candidates: [(String?, Bool)] = manifest.optionsUI?.openInTab == true
            ? [(options, true), (popup, false)]
            : [(popup, false), (options, true)]
        // Preserve packages already using a popup.html without declaring it.
        if options == nil && popup == nil { candidates.append(("popup.html", false)) }
        for (path, wide) in candidates {
            guard let path, !path.isEmpty, !path.hasPrefix("/"),
                  !path.contains("\\"), !path.contains("?"), !path.contains("#"),
                  !path.split(separator: "/").contains(".."),
                  path.lowercased().hasSuffix(".html") else { continue }
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            return SettingsPage(path: path, prefersWideLayout: wide)
        }
        return nil
    }

    static func installed(id: String, root: URL) throws -> ExtensionPackage {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        return ExtensionPackage(
            id: id,
            root: root.standardizedFileURL,
            manifest: try JSONDecoder().decode(InstalledExtensionManifest.self, from: data)
        )
    }
}

@MainActor
final class ExtensionRuntime {
    let packages: [ExtensionPackage]
    let loadIssues: [String: String]
    private let storageByID: [String: ExtensionStorage]

    init(installedRoots: [String: URL]? = nil) {
        var packages: [ExtensionPackage] = []
        var issues: [String: String] = [:]
        let store = ExtensionInstallStore()
        if installedRoots == nil, let issue = store.recoveryIssue {
            issues[ExtensionInstallStore.supportedExtensionID] = issue
        }
        let nyattoRoot = installedRoots == nil
            ? store.existingRoot : installedRoots?[ExtensionInstallStore.supportedExtensionID]
        if let root = nyattoRoot {
            do {
                let manifest = try ExtensionInstallStore.readAndValidateManifest(at: root)
                packages.append(ExtensionPackage(
                    id: ExtensionInstallStore.supportedExtensionID,
                    root: root,
                    manifest: manifest
                ))
            } catch {
                issues[ExtensionInstallStore.supportedExtensionID] = error.localizedDescription
            }
        }
        let homeStore = XHomeAnchorInstallStore()
        if installedRoots == nil, let issue = homeStore.recoveryIssue {
            issues[ExtensionPackage.homeAnchorID] = issue
        }
        let homeAnchorRoot = installedRoots == nil
            ? homeStore.existingRoot : installedRoots?[ExtensionPackage.homeAnchorID]
        if let root = homeAnchorRoot {
            do {
                _ = try XHomeAnchorInstallStore.validateManifest(at: root)
                packages.append(try ExtensionPackage.installed(id: ExtensionPackage.homeAnchorID, root: root))
            } catch {
                issues[ExtensionPackage.homeAnchorID] = error.localizedDescription
            }
        }
        let community = CommunityExtensionStore()
        let roots = installedRoots == nil ? community.installedRoots() : installedRoots!
        for (id, root) in roots.sorted(by: { $0.key < $1.key })
            where id != ExtensionInstallStore.supportedExtensionID
               && id != ExtensionPackage.homeAnchorID && id != "x-swipe-navigation" {
            do {
                _ = try CommunityExtensionStore.validateManifest(at: root)
                packages.append(try ExtensionPackage.installed(id: id, root: root))
            } catch {
                issues[id] = error.localizedDescription
            }
        }
        self.packages = packages
        self.loadIssues = issues
        storageByID = Dictionary(uniqueKeysWithValues: packages.map {
            ($0.id, ExtensionStorage(extensionID: $0.id))
        })
    }

    func makeBrowserConfiguration() throws -> (WKWebViewConfiguration, ExtensionHost?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Safari/604.1"
        configuration.allowsInlineMediaPlayback = true

        let host: ExtensionHost?
        if packages.isEmpty {
            host = nil
        } else {
            let extensionHost = try ExtensionHost(packages: packages, storageByID: storageByID)
            try extensionHost.installBrowserRuntime(into: configuration)
            host = extensionHost
        }
        try XtendNavigation.install(into: configuration)
        return (configuration, host)
    }

    func makeSettingsConfiguration(for extensionID: String) throws -> (WKWebViewConfiguration, ExtensionHost) {
        guard let package = packages.first(where: { $0.id == extensionID }),
              package.settingsPage != nil else {
            throw RuntimeError.missingExtensionResources
        }
        let host = try ExtensionHost(packages: [package], storageByID: storageByID)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        try host.installSettingsRuntime(into: configuration, extensionID: extensionID)
        return (configuration, host)
    }
}

/// パッケージごとにJavaScript実行領域、Chrome API、保存領域を分離する共通ホスト。
@MainActor
final class ExtensionHost: NSObject {
    private let packages: [ExtensionPackage]
    private let storageByID: [String: ExtensionStorage]
    private let resources: ExtensionResourceSchemeHandler
    private var bridges: [ChromeBridge] = []
    private var settingsExtensionID: String?
    private weak var webView: WKWebView?

    init(packages: [ExtensionPackage], storageByID: [String: ExtensionStorage]) throws {
        self.packages = packages
        self.storageByID = storageByID
        resources = ExtensionResourceSchemeHandler(
            rootsByID: Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0.root) })
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storageDidChange(_:)),
            name: ExtensionStorage.didChangeNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to webView: WKWebView) { self.webView = webView }

    func installBrowserRuntime(into configuration: WKWebViewConfiguration) throws {
        let controller = WKUserContentController()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(resources, forURLScheme: ExtensionResourceSchemeHandler.scheme)

        for package in packages {
            let world = ExtensionPackage.contentWorld(for: package.id)
            try installBridge(for: package, into: controller, world: world)
            addScript(
                try ChromeShim.javascript(manifest: package.manifest, extensionID: package.id),
                to: controller, world: world, time: .atDocumentStart
            )
            for entry in package.manifest.contentScripts ?? [] {
                let hosts = entry.matches
                    .filter { $0 == "https://x.com/*" || $0 == "https://twitter.com/*" }
                    .map { $0.contains("twitter.com") ? "twitter.com" : "x.com" }
                guard !hosts.isEmpty else { continue }
                let scriptWorld: WKContentWorld = entry.world == "MAIN" ? .page : world
                let time: WKUserScriptInjectionTime = entry.runAt == "document_idle" ? .atDocumentEnd : .atDocumentStart

                for (i, filename) in (entry.css ?? []).enumerated() {
                    let style = try jsonLiteral(source(named: filename, in: package))
                    let styleID = try jsonLiteral("xtend-style-\(package.id)-\(i)-\(filename)")
                    let hostNames = try jsonLiteral(hosts)
                    let script = """
                    (() => {
                      if (!\(hostNames).includes(location.hostname)) return;
                      const element = document.createElement('style');
                      element.id = \(styleID);
                      element.textContent = \(style);
                      (document.head || document.documentElement).appendChild(element);
                    })();
                    """
                    addScript(script, to: controller, world: world, time: time)
                }
                for filename in entry.js {
                    addScript(
                        onlyHosts(try source(named: filename, in: package), hosts: hosts),
                        to: controller, world: scriptWorld, time: time
                    )
                }
            }
        }
    }

    func installSettingsRuntime(into configuration: WKWebViewConfiguration, extensionID: String) throws {
        guard let package = packages.first(where: { $0.id == extensionID }) else {
            throw RuntimeError.missingResource(extensionID)
        }
        settingsExtensionID = extensionID
        let controller = WKUserContentController()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(resources, forURLScheme: ExtensionResourceSchemeHandler.scheme)
        try installBridge(for: package, into: controller, world: .page)
        addScript(
            try ChromeShim.javascript(manifest: package.manifest, extensionID: package.id),
            to: controller, world: .page, time: .atDocumentStart
        )
    }

    private func installBridge(
        for package: ExtensionPackage,
        into controller: WKUserContentController,
        world: WKContentWorld
    ) throws {
        guard let storage = storageByID[package.id] else { throw RuntimeError.missingStorage(package.id) }
        let handler: (([String: Any]) throws -> [String: Any])?
        if package.id == ExtensionInstallStore.supportedExtensionID {
            let support = try NyattoSupport(root: package.root)
            handler = { message in try support.handleRuntimeMessage(message) }
        } else {
            handler = nil
        }
        let bridge = ChromeBridge(storage: storage, runtimeMessageHandler: handler)
        bridges.append(bridge)
        controller.addScriptMessageHandler(
            bridge, contentWorld: world,
            name: ChromeShim.bridgeName(for: package.id)
        )
    }

    @objc private func storageDidChange(_ notification: Notification) {
        guard let webView,
              let extensionID = notification.userInfo?["extensionID"] as? String,
              storageByID[extensionID] != nil,
              let area = notification.userInfo?["area"] as? String,
              let changes = notification.userInfo?["changes"] as? [String: [String: Any]],
              let changesJSON = try? jsonLiteral(changes),
              let areaJSON = try? jsonLiteral(area) else { return }

        let world: WKContentWorld = settingsExtensionID == extensionID
            ? .page : ExtensionPackage.contentWorld(for: extensionID)
        let script = """
        if (typeof globalThis.__xtendDispatchStorageChange === 'function') {
          globalThis.__xtendDispatchStorageChange(\(changesJSON), \(areaJSON));
        }
        """
        webView.evaluateJavaScript(script, in: nil, in: world, completionHandler: nil)
    }

    private func source(named name: String, in package: ExtensionPackage) throws -> String {
        let candidate = package.root.appendingPathComponent(name).standardizedFileURL
        guard candidate.path.hasPrefix(package.root.path + "/") else {
            throw RuntimeError.missingResource(name)
        }
        do { return try String(contentsOf: candidate, encoding: .utf8) }
        catch { throw RuntimeError.missingResource(name) }
    }

    private func onlyHosts(_ script: String, hosts: [String]) -> String {
        let list = (try? jsonLiteral(hosts)) ?? "[]"
        return """
        (() => {
          if (!\(list).includes(location.hostname)) return;
          \(script)
        })();
        """
    }

    private func addScript(
        _ source: String, to controller: WKUserContentController,
        world: WKContentWorld, time: WKUserScriptInjectionTime
    ) {
        controller.addUserScript(WKUserScript(
            source: source, injectionTime: time,
            forMainFrameOnly: true, in: world
        ))
    }

    private func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let value = String(data: data, encoding: .utf8) else { throw RuntimeError.invalidJSONLiteral }
        return value
    }
}

enum RuntimeError: LocalizedError {
    case missingExtensionResources
    case missingResource(String)
    case missingStorage(String)
    case invalidJSONLiteral

    var errorDescription: String? {
        switch self {
        case .missingExtensionResources: "インストール済み拡張機能が見つかりません。"
        case .missingResource(let name): "拡張機能ファイルがありません: \(name)"
        case .missingStorage(let id): "拡張機能の保存領域がありません: \(id)"
        case .invalidJSONLiteral: "拡張機能の値をJSONに変換できません。"
        }
    }
}
