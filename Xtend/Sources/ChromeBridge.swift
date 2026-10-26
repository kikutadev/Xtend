import Foundation
import WebKit

/// WebKitメッセージから拡張機能単位の保存領域・専用メッセージ処理を呼び出す。
@MainActor
final class ChromeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let storage: ExtensionStorage
    private let extensionID: String
    private let trustedContext: Bool
    private let unlimitedStorage: Bool
    private let runtimeMessageHandler: (([String: Any]) throws -> [String: Any])?

    init(
        storage: ExtensionStorage,
        extensionID: String,
        trustedContext: Bool,
        unlimitedStorage: Bool,
        runtimeMessageHandler: (([String: Any]) throws -> [String: Any])?
    ) {
        self.storage = storage
        self.extensionID = extensionID
        self.trustedContext = trustedContext
        self.unlimitedStorage = unlimitedStorage
        self.runtimeMessageHandler = runtimeMessageHandler
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let request = message.body as? [String: Any],
              let operation = request["op"] as? String else {
            replyHandler(nil, "Malformed extension bridge request")
            return
        }

        do {
            // A settings WebView can navigate. Its Chrome bridge must only
            // be trusted at this extension's own resource origin.
            if trustedContext {
                let origin = message.frameInfo.securityOrigin
                guard origin.`protocol` == ExtensionResourceSchemeHandler.scheme,
                      origin.host == extensionID else { throw BridgeError.storageAccessDenied }
            }
            if operation.hasPrefix("storage.") {
                let area = try requiredString(request, key: "area")
                if !trustedContext {
                    guard try storage.allowsUntrusted(area: area) else {
                        throw BridgeError.storageAccessDenied
                    }
                }
            }
            switch operation {
            case "storage.get":
                let area = try requiredString(request, key: "area")
                replyHandler(try storage.get(area: area, keys: request["keys"]), nil)

            case "storage.set":
                let area = try requiredString(request, key: "area")
                guard let items = request["items"] as? [String: Any] else {
                    throw BridgeError.invalidPayload("items")
                }
                _ = try storage.set(area: area, items: items,
                                    quotaBytes: area == "local" && !unlimitedStorage ? 10 * 1024 * 1024 : nil)
                replyHandler(["ok": true], nil)

            case "storage.remove":
                let area = try requiredString(request, key: "area")
                _ = try storage.remove(area: area, keys: request["keys"])
                replyHandler(["ok": true], nil)

            case "storage.clear":
                let area = try requiredString(request, key: "area")
                _ = try storage.clear(area: area)
                replyHandler(["ok": true], nil)

            case "storage.getKeys":
                let area = try requiredString(request, key: "area")
                replyHandler(try storage.getKeys(area: area), nil)

            case "storage.getBytesInUse":
                let area = try requiredString(request, key: "area")
                replyHandler(try storage.getBytesInUse(area: area, keys: request["keys"]), nil)

            case "storage.setAccessLevel":
                let area = try requiredString(request, key: "area")
                guard let level = request["accessLevel"] as? String else {
                    throw BridgeError.invalidPayload("accessLevel")
                }
                try storage.setAccessLevel(area: area, level: level)
                replyHandler(["ok": true], nil)

            case "runtime.sendMessage":
                guard let runtimeMessage = request["message"] as? [String: Any] else {
                    throw BridgeError.invalidPayload("message")
                }
                replyHandler(try runtimeMessageHandler?(runtimeMessage) ?? ["ok": false], nil)

            default:
                throw BridgeError.unsupportedOperation(operation)
            }
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    private func requiredString(_ request: [String: Any], key: String) throws -> String {
        guard let value = request[key] as? String else {
            throw BridgeError.invalidPayload(key)
        }
        return value
    }
}

enum BridgeError: LocalizedError {
    case invalidPayload(String)
    case unsupportedOperation(String)
    case storageAccessDenied

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let key): "Invalid extension bridge payload: \(key)"
        case .unsupportedOperation(let operation): "Unsupported extension bridge operation: \(operation)"
        case .storageAccessDenied: "chrome.storage is not accessible from this content script"
        }
    }
}
