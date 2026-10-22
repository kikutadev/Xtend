import Foundation
import WebKit

/// にゃっとランドだけが使う画像パック応答と受け入れ確認。
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

    func runAcceptanceProbe(on webView: WKWebView, in world: WKContentWorld) {
        #if DEBUG
        let testAsset = "images/organic/cat/cat01/01/cat01_spritesheets/cat01_attack_strip7.png"
        let script = """
        const key = '__xtend_probe';
        await chrome.storage.local.set({ [key]: 'ok' });
        const stored = await chrome.storage.local.get([key]);
        await chrome.storage.local.remove([key]);
        const response = await chrome.runtime.sendMessage({ type: 'xff:asset-batch', paths: ['\(testAsset)'] });
        return stored[key] === 'ok' && response?.ok === true && typeof response.assets?.['\(testAsset)'] === 'string' ? 1 : 0;
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: world) { result in
            switch result {
            case .success(let value):
                print("NYATTO_ACCEPTANCE bridge_probe=\(value)")
            case .failure(let error):
                print("NYATTO_ACCEPTANCE bridge_probe_error=\(error.localizedDescription)")
            }
        }
        #endif
    }
}
