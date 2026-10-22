import Foundation

/// 各拡張機能の隔離されたJavaScript環境に公開するChrome APIの最小実装。
enum ChromeShim {
    static func bridgeName(for extensionID: String) -> String {
        "xtendBridge_\(extensionID.replacingOccurrences(of: "-", with: "_"))"
    }

    static func javascript(manifest: InstalledExtensionManifest, extensionID: String) throws -> String {
        let id = try jsonLiteral(extensionID)
        let bridgeName = try jsonLiteral(bridgeName(for: extensionID))
        let name = try jsonLiteral(manifest.name ?? extensionID)
        let version = try jsonLiteral(manifest.version)
        let versionName = try jsonLiteral(manifest.versionName ?? manifest.version)

        return #"""
        (() => {
          'use strict';
          const extensionID = \#(id);
          if (globalThis.chrome?.runtime?.id === extensionID) return;
          const bridge = globalThis.webkit?.messageHandlers?.[\#(bridgeName)];
          if (!bridge) return;

          const storageListeners = new Set();
          const messageListeners = new Set();
          let lastError = null;

          const onMessage = Object.freeze({
            addListener(listener) { if (typeof listener === 'function') messageListeners.add(listener); },
            removeListener(listener) { messageListeners.delete(listener); },
            hasListener(listener) { return messageListeners.has(listener); }
          });

          const runtime = Object.freeze({
            id: extensionID,
            get lastError() { return lastError; },
            getURL(path = '') {
              const relative = String(path ?? '').replace(/^\/+/, '');
              return `xtend-extension://${extensionID}/${relative}`;
            },
            getManifest() {
              return Object.freeze({
                manifest_version: 3,
                name: \#(name),
                version: \#(version),
                version_name: \#(versionName)
              });
            },
            onMessage,
            sendMessage(message, callback) {
              return invoke('runtime.sendMessage', { message }, callback);
            }
          });

          function invoke(op, payload, callback) {
            const promise = bridge.postMessage({ op, ...payload });
            if (typeof callback !== 'function') return promise;
            promise.then(
              value => { lastError = null; callback(value); },
              error => {
                lastError = { message: String(error?.message || error || 'Extension bridge error') };
                callback(undefined);
                queueMicrotask(() => { lastError = null; });
              }
            );
            return undefined;
          }

          function makeStorageArea(area) {
            return Object.freeze({
              get(keys, callback) { return invoke('storage.get', { area, keys: keys ?? null }, callback); },
              set(items, callback) { return invoke('storage.set', { area, items: items || {} }, callback); },
              remove(keys, callback) { return invoke('storage.remove', { area, keys: keys ?? null }, callback); }
            });
          }

          const onChanged = Object.freeze({
            addListener(listener) { if (typeof listener === 'function') storageListeners.add(listener); },
            removeListener(listener) { storageListeners.delete(listener); },
            hasListener(listener) { return storageListeners.has(listener); }
          });

          globalThis.__xtendDispatchStorageChange = (changes, area) => {
            for (const listener of [...storageListeners]) {
              try { listener(changes || {}, area); } catch (_) {}
            }
          };

          Object.defineProperty(globalThis, 'chrome', {
            value: Object.freeze({
              runtime,
              storage: Object.freeze({
                local: makeStorageArea('local'),
                sync: makeStorageArea('sync'),
                onChanged
              })
            }),
            configurable: false,
            enumerable: true,
            writable: false
          });
        })();
        """#
    }

    private static func jsonLiteral(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let string = String(data: data, encoding: .utf8) else {
            throw RuntimeError.invalidJSONLiteral
        }
        return string
    }
}
