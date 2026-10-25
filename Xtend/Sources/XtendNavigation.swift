import WebKit

/// Xtend's native browser behavior, separate from optional Chrome extensions.
@MainActor
enum XtendNavigation {
    static func install(into configuration: WKWebViewConfiguration) throws {
        for name in ["xtend-swipe", "xtend-quote-longpress"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
                throw RuntimeError.missingResource("\(name).js")
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
}
