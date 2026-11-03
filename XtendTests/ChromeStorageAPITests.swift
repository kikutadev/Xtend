import Foundation
import UIKit
import WebKit
import XCTest
@testable import Xtend

@MainActor
final class ChromeStorageAPITests: XCTestCase {
    private func store() throws -> (ExtensionStorage, UserDefaults, URL, String) {
        let suite = "Xtend.ChromeAPI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        return (ExtensionStorage(extensionID: "api-test", defaults: defaults, storageDirectory: directory),
                defaults, directory, suite)
    }

    func testGetKeysBytesAndClear() throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        _ = try storage.set(area: "local", items: ["a": "A", "number": 5, "empty": NSNull()])
        _ = try storage.set(area: "sync", items: ["protected": true])
        XCTAssertEqual(try storage.getKeys(area: "local"), ["a", "empty", "number"])
        XCTAssertEqual(try storage.getBytesInUse(area: "local", keys: "a"), 4) // a + "A"
        XCTAssertEqual(try storage.getBytesInUse(area: "local", keys: ["a", "a", "missing"]), 4)
        XCTAssertEqual(try storage.getBytesInUse(area: "local", keys: nil), 4 + 9 + 7) // null + number
        XCTAssertThrowsError(try storage.getBytesInUse(area: "local", keys: 33))
        let changes = try storage.clear(area: "local")
        XCTAssertEqual(Set(changes.keys), Set(["a", "empty", "number"]))
        XCTAssertTrue(changes.values.allSatisfy { $0["oldValue"] != nil && $0["newValue"] == nil })
        XCTAssertTrue(try storage.getKeys(area: "local").isEmpty)
        XCTAssertEqual(try storage.get(area: "sync", keys: "protected")["protected"] as? Bool, true)
        XCTAssertTrue(try storage.clear(area: "local").isEmpty)
        XCTAssertTrue(try ExtensionStorage(extensionID: "api-test", defaults: defaults,
                                           storageDirectory: directory).getKeys(area: "local").isEmpty)
    }

    func testNullBytesEmojiAndJSONValuesDoNotTruncateKeys() throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let key = "part\0middle🧪"
        let value = ["日本語": ["🧪", "\0", "末尾"]]
        _ = try storage.set(area: "local", items: [key: value, "empty": ""])
        XCTAssertTrue(try storage.getKeys(area: "local").contains(key))
        let fetched = try storage.get(area: "local", keys: key)[key] as? [String: [String]]
        XCTAssertEqual(fetched?["日本語"], value["日本語"])
        XCTAssertGreaterThan(try storage.getBytesInUse(area: "local", keys: key), key.utf8.count)
        _ = try storage.remove(area: "local", keys: key)
        XCTAssertNil(try storage.get(area: "local", keys: key)[key])
        XCTAssertEqual(try storage.getKeys(area: "local"), ["empty"])
    }


    func testAccessLevelAndQuotaRollback() throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try storage.allowsUntrusted(area: "local"))
        try storage.setAccessLevel(area: "local", level: "TRUSTED_CONTEXTS")
        XCTAssertFalse(try storage.allowsUntrusted(area: "local"))
        XCTAssertFalse(try ExtensionStorage(extensionID: "api-test", defaults: defaults,
                                            storageDirectory: directory).allowsUntrusted(area: "local"))
        XCTAssertTrue(try storage.allowsUntrusted(area: "sync"))
        XCTAssertThrowsError(try storage.setAccessLevel(area: "local", level: "invalid"))
        try storage.setAccessLevel(area: "local", level: "TRUSTED_AND_UNTRUSTED_CONTEXTS")
        XCTAssertTrue(try storage.allowsUntrusted(area: "local"))
        _ = try storage.set(area: "local", items: ["old": "A"])
        XCTAssertThrowsError(try storage.set(area: "local", items: ["valid": "B", "large": String(repeating: "q", count: 40)], quotaBytes: 15))
        XCTAssertNil(try storage.get(area: "local", keys: "valid")["valid"])
        XCTAssertEqual(try storage.get(area: "local", keys: "old")["old"] as? String, "A")
        _ = try storage.set(area: "local", items: ["valid": "B"], quotaBytes: 15)
        XCTAssertEqual(try storage.getBytesInUse(area: "local", keys: nil), 14)
        try storage.eraseAll()
        XCTAssertTrue(try storage.allowsUntrusted(area: "local"))
    }

    private final class PageLoaded: NSObject, WKNavigationDelegate {
        let callback: XCTestExpectation
        init(_ callback: XCTestExpectation) { self.callback = callback }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { callback.fulfill() }
    }

    private final class ResourceScheme: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let bytes = Data("<html><body>Isolated extension test</body></html>".utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html",
                                        expectedContentLength: bytes.count, textEncodingName: "utf-8"))
            task.didReceive(bytes)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    @MainActor
    private final class StorageEventForwarder: NSObject {
        let web: WKWebView
        let world: WKContentWorld
        init(web: WKWebView, world: WKContentWorld) {
            self.web = web
            self.world = world
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                name: ExtensionStorage.didChangeNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func changed(_ note: Notification) {
            guard let area = note.userInfo?["area"] as? String,
                  let changes = note.userInfo?["changes"] as? [String: [String: Any]],
                  JSONSerialization.isValidJSONObject(changes),
                  let raw = try? JSONSerialization.data(withJSONObject: changes),
                  let text = String(data: raw, encoding: .utf8) else { return }
            let areaJSON = "\"\(area)\""
            web.evaluateJavaScript("globalThis.__xtendDispatchStorageChange(\(text),\(areaJSON));",
                                   in: nil, in: world, completionHandler: nil)
        }
    }

    private func webFixture(storage: ExtensionStorage, trusted: Bool, unlimited: Bool = false) async throws
        -> (WKWebView, UIWindow, ChromeBridge, PageLoaded, WKContentWorld, StorageEventForwarder) {
        let configuration = WKWebViewConfiguration()
        let content = WKUserContentController()
        configuration.userContentController = content
        if trusted { configuration.setURLSchemeHandler(ResourceScheme(), forURLScheme: "xtend-extension") }
        let world: WKContentWorld = trusted ? .page : .world(name: "Xtend.Extension.api-test")
        let manifest = try JSONDecoder().decode(InstalledExtensionManifest.self,
            from: Data("{\"manifest_version\":3,\"name\":\"QA\",\"version\":\"1.0\",\"permissions\":[\"storage\"]}".utf8))
        let name = ChromeShim.bridgeName(for: "api-test")
        let bridge = ChromeBridge(storage: storage, extensionID: "api-test", trustedContext: trusted,
                                  unlimitedStorage: unlimited, runtimeMessageHandler: nil)
        content.addScriptMessageHandler(bridge, contentWorld: world, name: name)
        content.addUserScript(WKUserScript(source: try ChromeShim.javascript(manifest: manifest, extensionID: "api-test"),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.rootViewController!.view.addSubview(web)
        window.isHidden = false
        let expected = expectation(description: "storage fixture loaded")
        let navigation = PageLoaded(expected)
        web.navigationDelegate = navigation
        if trusted {
            web.load(URLRequest(url: URL(string: "xtend-extension://api-test/options.html")!))
        } else {
            web.loadHTMLString("<html><body><h1>Storage bridge QA</h1></body></html>",
                               baseURL: URL(string: "https://x.com/home")!)
        }
        await fulfillment(of: [expected], timeout: 15)
        let forwarder = StorageEventForwarder(web: web, world: world)
        return (web, window, bridge, navigation, world, forwarder)
    }

    private func js(_ script: String, web: WKWebView, world: WKContentWorld) async throws -> String {
        let value = try await web.callAsyncJavaScript("return await (\(script));", arguments: [:],
                                                      in: nil, contentWorld: world)
        return String(describing: value)
    }

    func testActualJavaScriptStorageAPIWithBridge() async throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let (web, window, _, _, world, forwarder) = try await webFixture(storage: storage, trusted: true)
        defer { window.isHidden = true }
        let report = try await js("""
          (async () => {
            const a = chrome.storage.local;
            const records=[];
            const same= (actual,expected) => {if(JSON.stringify(actual)!==JSON.stringify(expected)) throw Error(JSON.stringify({actual,expected}));};
            same(await a.get(),{});
            same(await a.get('missing'),{});
            same(await a.get({missing:12}),{missing:12});
            await a.set({alpha:'abc', count:8, nested:{a:[1,2]}, empty:null});
            same((await a.get('alpha')).alpha,'abc');
            same((await a.get(['alpha','count'])).count,8);
            same(await a.get({missing:'default'}),{missing:'default'});
            if((await a.getKeys()).sort().join(',')!=='alpha,count,empty,nested') throw Error('keys');
            if(await a.getBytesInUse('alpha')!==10) throw Error('bytes'); // 5 key + 5 JSON
            if(await a.getBytesInUse(['alpha','alpha'])!==10) throw Error('duplicate bytes');
            const changed=(changes,area)=>records.push({area,keys:Object.keys(changes).sort()});
            const localChanges=changes=>records.push({localOnly:true,keys:Object.keys(changes).sort()});
            a.onChanged.addListener(localChanges);
            chrome.storage.onChanged.addListener(changed);
            await a.set({alpha:'abc'});  // unchanged
            await a.remove('count');
            await a.clear();
            await a.clear();
            await chrome.storage.sync.set({option:1});
            same(await a.get(),{});
            same(await a.getKeys(),[]);
            if(await a.getBytesInUse()!==0) throw Error('bytes after clear');
            if((await chrome.storage.sync.get('option')).option!==1) throw Error('sync isolation');
            if(a.QUOTA_BYTES!==10485760) throw Error('constant');
            await new Promise(r=>setTimeout(r,250));
            if(records.length!==5) throw Error('wrong event count '+JSON.stringify(records));
            a.onChanged.removeListener(localChanges);
            if(a.onChanged.hasListener(localChanges)) throw Error('listener leaked');
            chrome.storage.onChanged.removeListener(changed);
            const callbackKeys=await new Promise(resolve=>a.getKeys(resolve));
            same(callbackKeys, []);
            const callbackRemove=await new Promise(resolve=>a.remove('missing',(...args)=>resolve({args:args.length,error:chrome.runtime.lastError})));
            const callbackClear=await new Promise(resolve=>a.clear((...args)=>resolve({args:args.length,error:chrome.runtime.lastError})));
            if(callbackRemove.args!==0 || callbackClear.args!==0 || callbackClear.error || callbackRemove.error) throw Error('void callbacks');
            return JSON.stringify({success:true,records});
          })()
        """, web: web, world: world)
        withExtendedLifetime(forwarder) {}
        XCTAssertTrue(String(describing: report).contains("success"))
    }

    func testActualJavaScriptQuotaAndUnlimitedPermission() async throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let (web, window, _, _, world, forwarder) = try await webFixture(storage: storage, trusted: true)
        defer { window.isHidden = true }
        let limited = try await js("""
          (async()=>{
            const big='q'.repeat(10*1024*1024);
            try {await chrome.storage.local.set({oversize:big});return 'FAILED_TO_REJECT'}
            catch(e){return String(e?.message||e).includes('quota') ? 'QUOTA_REJECTED' : 'WRONG_ERROR'}
          })()
        """, web:web, world:world)
        XCTAssertTrue(limited.contains("QUOTA_REJECTED"), limited)
        XCTAssertTrue(try storage.getKeys(area: "local").isEmpty)
        // Native API can accept the same value with explicit unlimited quota
        // permission; this must not leak into sync or another extension.
        let payload = String(repeating: "q", count: 11 * 1024 * 1024)
        _ = try storage.set(area: "local", items: ["large": payload], quotaBytes: nil)
        XCTAssertEqual((try storage.get(area: "local", keys: "large")["large"] as? String)?.count,
                       11 * 1024 * 1024)
        withExtendedLifetime(forwarder) {}
    }


    func testUnlimitedPermissionAllowsLargerWebKitStorageMessages() async throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let (web, window, _, _, world, _) = try await webFixture(storage: storage, trusted: true, unlimited: true)
        defer { window.isHidden = true }
        let result = try await js("""
          (async()=>{
            const data='q'.repeat(11*1024*1024);
            await chrome.storage.local.set({large:data});
            const values=await chrome.storage.local.get('large');
            return values.large.length === data.length ? 'UNLIMITED_SAVED' : 'DATA_MISMATCH';
          })()
        """, web:web, world:world)
        XCTAssertTrue(result.contains("UNLIMITED_SAVED"), result)
        XCTAssertGreaterThan(try storage.getBytesInUse(area: "local", keys: nil), 10*1024*1024)
    }

    func testSettingsBridgeRejectsNavigationToOtherOrigins() async throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let (web, window, _, _, world, _) = try await webFixture(storage: storage, trusted: true)
        defer { window.isHidden = true }
        let loaded = expectation(description: "navigated to untrusted page")
        let delegate = PageLoaded(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("<html><body>Untrusted destination</body></html>",
                           baseURL: URL(string: "https://example.org/untrusted")!)
        await fulfillment(of: [loaded], timeout: 15)
        let result = try await js("""
          (async()=>{
            try { await chrome.storage.local.get(); return 'INCORRECTLY_ALLOWED'; }
            catch(e) { return 'DENIED'; }
          })()
        """, web: web, world: world)
        XCTAssertTrue(result.contains("DENIED"), result)
    }

    func testCallbackLastErrorAccessLevelAndContentScriptIsolation() async throws {
        let (storage, defaults, directory, suite) = try store()
        defer { storage.close(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let (trusted, trustedWindow, _, _, trustedWorld, _) = try await webFixture(storage: storage, trusted: true)
        let (untrusted, untrustedWindow, _, _, untrustedWorld, _) = try await webFixture(storage: storage, trusted: false)
        defer { trustedWindow.isHidden = true; untrustedWindow.isHidden = true }
        let result = try await js("""
          (async()=>{
            const a=chrome.storage.local;
            const callbackSet=await new Promise(resolve=>a.set({secret:'hidden'},(...args)=>resolve({args:args.length,error:chrome.runtime.lastError})));
            const callbackGet=await new Promise(resolve=>a.get(value=>resolve({value,error:chrome.runtime.lastError})));
            const callbackBytes=await new Promise(resolve=>a.getBytesInUse(value=>resolve({value,error:chrome.runtime.lastError})));
            const bad=await new Promise(resolve=>a.setAccessLevel({accessLevel:'INVALID'},()=>resolve(chrome.runtime.lastError?.message)));
            const cleaned=chrome.runtime.lastError===null;
            await a.setAccessLevel({accessLevel:'TRUSTED_CONTEXTS'});
            return JSON.stringify({callbackSet,callbackGet,callbackBytes,bad,cleaned});
          })()
        """, web: trusted, world: trustedWorld)
        let text = String(describing: result)
        XCTAssertTrue(text.contains("hidden"), text)
        XCTAssertTrue(text.contains("Unsupported"), text)
        XCTAssertTrue(try !storage.allowsUntrusted(area: "local"))
        let blocked = try await js("""
          (async()=>{
            const a=chrome.storage.local;
            let rejected=false;
            try {await a.get('secret')}catch(e){rejected=true}
            const callback=await new Promise(resolve=>a.get('secret',v=>resolve({error:!!chrome.runtime.lastError,value:v})));
            return JSON.stringify({rejected,callback});
          })()
        """, web: untrusted, world: untrustedWorld)
        XCTAssertTrue(String(describing: blocked).contains("rejected"))
        XCTAssertTrue(String(describing: blocked).contains("true"))
        try await js("chrome.storage.local.setAccessLevel({accessLevel:'TRUSTED_AND_UNTRUSTED_CONTEXTS'})",web:trusted,world:trustedWorld)
        let restored = try await js("chrome.storage.local.get('secret')",web:untrusted,world:untrustedWorld)
        XCTAssertNotNil(restored)
    }
}
