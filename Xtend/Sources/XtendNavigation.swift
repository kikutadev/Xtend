import WebKit

/// Xtend's native browser behavior, separate from optional Chrome extensions.
@MainActor
enum XtendNavigation {
    static func install(into configuration: WKWebViewConfiguration) throws {
        guard let url = Bundle.main.url(forResource: "xtend-swipe", withExtension: "js") else {
            throw RuntimeError.missingResource("xtend-swipe.js")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        configuration.userContentController.addUserScript(WKUserScript(
            source: source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: WKContentWorld.world(name: "Xtend.Navigation")
        ))
    }
}
