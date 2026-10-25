import WebKit

/// Xtend-only local preferences. Enabled by default to preserve the existing behavior.
enum XPromoPreferences {
    private static let prefix = "xtend.hidePromotions."

    private static func read(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: prefix + key) as? Bool ?? true
    }

    static var enabled: Bool {
        get { read("enabled") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "enabled") }
    }

    static var getApp: Bool {
        get { read("getApp") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "getApp") }
    }

    static var subscribe: Bool {
        get { read("subscribe") }
        set { UserDefaults.standard.set(newValue, forKey: prefix + "subscribe") }
    }

    static var javascriptObject: String {
        "{enabled: \(enabled), getApp: \(getApp), subscribe: \(subscribe)}"
    }
}

/// Injects the X settings entry and spotlight independently of optional extensions.
@MainActor
enum XtendSettingsMenu {
    static func install(
        into configuration: WKWebViewConfiguration,
        showTip: Bool,
        onMessage: @escaping (WKScriptMessage) -> Void
    ) throws {
        guard let url = Bundle.main.url(forResource: "xtend-settings-menu", withExtension: "js") else {
            throw RuntimeError.missingResource("xtend-settings-menu.js")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let world = WKContentWorld.world(name: "Xtend.Settings")
        let controller = configuration.userContentController
        controller.add(SettingsMenuBridge(onMessage: onMessage), contentWorld: world, name: "xtendSettings")
        controller.addUserScript(WKUserScript(
            source: "const __xtendShowSettingsTip = \(showTip ? "true" : "false");\n"
                + "const __xtendPromoSettings = \(XPromoPreferences.javascriptObject);\n"
                + source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
    }

    static func updatePreferences(in webView: WKWebView) {
        // Evaluate in the same isolated content world as the existing menu script.
        // Changing a switch does not reload X or discard the current reading position.
        webView.evaluateJavaScript(
            "globalThis.__xtendSetPromoSettings?.(\(XPromoPreferences.javascriptObject))",
            in: nil, in: WKContentWorld.world(name: "Xtend.Settings")
        ) { _ in }
    }
}

@MainActor
private final class SettingsMenuBridge: NSObject, WKScriptMessageHandler {
    private let onMessage: (WKScriptMessage) -> Void

    init(onMessage: @escaping (WKScriptMessage) -> Void) {
        self.onMessage = onMessage
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message)
    }
}
