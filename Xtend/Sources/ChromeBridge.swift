import Foundation
import OSLog
import WebKit

/// WebKitメッセージから拡張機能単位の保存領域・専用メッセージ処理を呼び出す。
@MainActor
final class ChromeBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let storage: ExtensionStorage
    private let runtimeMessageHandler: (([String: Any]) throws -> [String: Any])?
    private let logger = Logger(subsystem: "Xtend", category: "ExtensionStorage")

    init(
        storage: ExtensionStorage,
        runtimeMessageHandler: (([String: Any]) throws -> [String: Any])?
    ) {
        self.storage = storage
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
            switch operation {
            case "storage.get":
                let area = try requiredString(request, key: "area")
                let values = try storage.get(area: area, keys: request["keys"])
                #if DEBUG
                if (request["keys"] as? [String])?.contains("xff:liked-by") == true {
                    logger.debug("Nyatto ring history read: area=\(area, privacy: .public), present=\(values["xff:liked-by"] != nil)")
                }
                #endif
                replyHandler(values, nil)

            case "storage.set":
                let area = try requiredString(request, key: "area")
                guard let items = request["items"] as? [String: Any] else {
                    throw BridgeError.invalidPayload("items")
                }
                _ = try storage.set(area: area, items: items)
                #if DEBUG
                if items["xff:liked-by"] != nil {
                    logger.debug("Nyatto ring history saved: area=\(area, privacy: .public)")
                }
                #endif
                replyHandler(["ok": true], nil)

            case "storage.remove":
                let area = try requiredString(request, key: "area")
                _ = try storage.remove(area: area, keys: request["keys"])
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
            if operation.hasPrefix("storage.") {
                logger.error("Extension storage error: operation=\(operation, privacy: .public), error=\(error.localizedDescription, privacy: .private)")
            }
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

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let key): "Invalid extension bridge payload: \(key)"
        case .unsupportedOperation(let operation): "Unsupported extension bridge operation: \(operation)"
        }
    }
}
