import Foundation

/// にゃっとランドだけが使う画像パック応答。
@MainActor
final class NyattoSupport {
    private let packedAssets: PackedAssetStore

    init(root: URL) throws {
        packedAssets = try PackedAssetStore(root: root)
    }

    func handleRuntimeMessage(_ message: [String: Any]) throws -> [String: Any] {
        guard message["type"] as? String == "xff:asset-batch",
              let paths = message["paths"] as? [String] else {
            return ["ok": false]
        }
        do {
            return ["ok": true, "assets": try packedAssets.base64Assets(for: paths)]
        } catch {
            #if DEBUG
            print("NYATTO_ASSET_ERROR \(error.localizedDescription)")
            #endif
            return ["ok": false]
        }
    }
}
