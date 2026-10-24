import WebKit

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
            source: "const __xtendShowSettingsTip = \(showTip ? "true" : "false");\n" + source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
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
