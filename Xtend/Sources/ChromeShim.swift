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

          // Promise and callback forms share one error/return contract.
          // Mutation callbacks receive no value. runtime.lastError is scoped
          // to the callback invocation, even if a callback itself throws.
          function invoke(op, payload, callback, returnsVoid = false) {
            const promise = bridge.postMessage({ op, ...payload }).then(
              value => returnsVoid ? undefined : value
            );
            if (typeof callback !== 'function') return promise;
            promise.then(
              value => { lastError = null; returnsVoid ? callback() : callback(value); },
              error => {
                lastError = { message: String(error?.message || error || 'Extension bridge error') };
                try { returnsVoid ? callback() : callback(undefined); }
                finally { queueMicrotask(() => { lastError = null; }); }
              }
            );
            return undefined;
          }

          const storageListeners = new Set();
          const areaListeners = { local: new Set(), sync: new Set() };
          const event = listeners => Object.freeze({
            addListener(fn) { if (typeof fn === 'function') listeners.add(fn); },
            removeListener(fn) { listeners.delete(fn); },
            hasListener(fn) { return listeners.has(fn); }
          });
          const onChanged = event(storageListeners);
          function makeStorageArea(area) {
            return Object.freeze({
              QUOTA_BYTES: area === 'local' ? 10485760 : 102400,
              get(keys, callback) {
                if (typeof keys === 'function') { callback = keys; keys = null; }
                return invoke('storage.get', { area, keys: keys ?? null }, callback);
              },
              getKeys(callback) { return invoke('storage.getKeys', { area }, callback); },
              getBytesInUse(keys, callback) {
                if (typeof keys === 'function') { callback = keys; keys = null; }
                return invoke('storage.getBytesInUse', { area, keys: keys ?? null }, callback);
              },
              set(items, callback) { return invoke('storage.set', { area, items }, callback, true); },
              remove(keys, callback) { return invoke('storage.remove', { area, keys }, callback, true); },
              clear(callback) { return invoke('storage.clear', { area }, callback, true); },
              setAccessLevel(options, callback) {
                return invoke('storage.setAccessLevel', { area, accessLevel: options?.accessLevel }, callback, true);
              },
              onChanged: event(areaListeners[area])
            });
          }

          globalThis.__xtendDispatchStorageChange = (changes, area) => {
            for (const listener of [...storageListeners]) {
              try { listener(changes || {}, area); } catch (_) {}
            }
            for (const listener of [...(areaListeners[area] || [])]) {
              try { listener(changes || {}); } catch (_) {}
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
