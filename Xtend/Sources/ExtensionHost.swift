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
    private let storageByID: [String: ExtensionStorage]

    init() throws {
        var packages: [ExtensionPackage] = []
        let store = ExtensionInstallStore()
        if let root = store.installedExtensionRoot {
            let manifest = try ExtensionInstallStore.readAndValidateManifest(at: root)
            packages.append(ExtensionPackage(
                id: ExtensionInstallStore.supportedExtensionID,
                root: root,
                manifest: manifest
            ))
        }
        if let root = XHomeAnchorInstallStore().installedRoot {
            packages.append(try ExtensionPackage.installed(id: ExtensionPackage.homeAnchorID, root: root))
        }
        self.packages = packages
        storageByID = Dictionary(uniqueKeysWithValues: packages.map {
            ($0.id, ExtensionStorage(extensionID: $0.id))
        })
    }

    func makeBrowserConfiguration() throws -> (WKWebViewConfiguration, ExtensionHost?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // X redirects the bare WKWebView UA to a Safari-only custom URL.
        configuration.applicationNameForUserAgent = "Safari/604.1"
        configuration.allowsInlineMediaPlayback = true
        guard !packages.isEmpty else { return (configuration, nil) }
        let host = try ExtensionHost(packages: packages, storageByID: storageByID)
        try host.installBrowserRuntime(into: configuration)
        return (configuration, host)
    }

    func makeSettingsConfiguration() throws -> (WKWebViewConfiguration, ExtensionHost) {
        guard let primary = packages.first(where: { $0.id == ExtensionInstallStore.supportedExtensionID }) else {
            throw RuntimeError.missingExtensionResources
        }
        let host = try ExtensionHost(packages: [primary], storageByID: storageByID)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        try host.installSettingsRuntime(into: configuration, extensionID: primary.id)
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
    private var nyattoSupport: NyattoSupport?
    private var settingsExtensionID: String?
    private weak var webView: WKWebView?

    init(packages: [ExtensionPackage], storageByID: [String: ExtensionStorage]) throws {
        self.packages = packages
        self.storageByID = storageByID
        resources = ExtensionResourceSchemeHandler(
            rootsByID: Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0.root) })
        )
        super.init()
        for package in packages {
            guard let storage = storageByID[package.id] else { throw RuntimeError.missingStorage(package.id) }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(storageDidChange(_:)),
                name: ExtensionStorage.didChangeNotification,
                object: storage
            )
        }
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
            nyattoSupport = support
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

    func runNyattoAcceptanceProbe() {
        guard let webView, let nyattoSupport else { return }
        nyattoSupport.runAcceptanceProbe(
            on: webView,
            in: ExtensionPackage.contentWorld(for: ExtensionInstallStore.supportedExtensionID)
        )
    }

    @objc private func storageDidChange(_ notification: Notification) {
        guard let webView,
              let storage = notification.object as? ExtensionStorage,
              let entry = storageByID.first(where: { $0.value === storage }),
              let area = notification.userInfo?["area"] as? String,
              let changes = notification.userInfo?["changes"] as? [String: [String: Any]],
              let changesJSON = try? jsonLiteral(changes),
              let areaJSON = try? jsonLiteral(area) else { return }

        let world: WKContentWorld = settingsExtensionID == entry.key
            ? .page : ExtensionPackage.contentWorld(for: entry.key)
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
