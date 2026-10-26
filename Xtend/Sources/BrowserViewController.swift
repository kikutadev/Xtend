import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let initialURL: URL?
    private var runtime: ExtensionRuntime?
    private var extensionHost: ExtensionHost?
    private var webView: WKWebView?
    #if DEBUG
    private var prewarmProbeView: WKWebView?
    private var prewarmProbeHost: ExtensionHost?
    #endif
    private weak var navigationBackButton: UIButton?
    private weak var settingsButton: UIButton?
    private var pageLoadFailed = false
    private static let settingsTipSeenKey = "xtend.settingsMenuTipSeen"
    private var pendingExtensionChanges = false
    private var hasShownExtensionWarning = false
    private var runtimeError: String?
    private var lastWebProcessTermination: Date?
    private var isShowingNavigationError = false

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        installSettingsButton()
        installBackButton()
        buildBrowser(initialURL ?? URL(string: "https://x.com/home")!)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasShownExtensionWarning, presentedViewController == nil else { return }
        let issues = runtime?.loadIssues ?? [:]
        guard !issues.isEmpty || runtimeError != nil else { return }
        hasShownExtensionWarning = true
        let names = issues.keys.map { id in
            switch id {
            case ExtensionPackage.homeAnchorID: "X ホームの閲覧位置"
            default: "にゃっとランドforX"
            }
        }.sorted()
        let message = names.isEmpty
            ? (runtimeError ?? "拡張機能の読み込みに失敗しました。")
            : "\(names.joined(separator: "、"))を無効化しました。Xは引き続き利用できます。設定画面から修復できます。"
        let alert = UIAlertController(title: "拡張機能の読み込みに失敗しました", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "あとで", style: .cancel))
        alert.addAction(UIAlertAction(title: "設定へ", style: .default) { [weak self] _ in
            self?.openSettings()
        })
        present(alert, animated: true)
    }

    private func buildBrowser(_ url: URL) {
        #if DEBUG
        prewarmProbeView?.removeFromSuperview()
        prewarmProbeView = nil
        prewarmProbeHost = nil
        #endif
        let runtime = ExtensionRuntime()
        let configuration: WKWebViewConfiguration
        let host: ExtensionHost?
        do {
            (configuration, host) = try runtime.makeBrowserConfiguration()
            runtimeError = nil
        } catch {
            // Even an unexpected host failure must never lock the user out of X.
            let fallback = WKWebViewConfiguration()
            fallback.websiteDataStore = .default()
            fallback.applicationNameForUserAgent = "Safari/604.1"
            fallback.allowsInlineMediaPlayback = true
            // Built-in navigation must remain available even when an optional
            // extension host unexpectedly fails.
            try? XtendNavigation.install(into: fallback)
            configuration = fallback
            host = nil
            runtimeError = error.localizedDescription
            hasShownExtensionWarning = false
        }
        installSettingsMenu(into: configuration)
        let browser = WKWebView(frame: .zero, configuration: configuration)
        host?.attach(to: browser)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        self.runtime = runtime
        self.extensionHost = host
        self.webView = browser
        configure(browser)
        updateNavigationControls(for: browser, url: url)
        view.sendSubviewToBack(browser)
        browser.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--xtend-probe-preload") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak browser] in
                guard let self, let browser, self.webView === browser else { return }
                self.startPrewarmProbe()
            }
        }
        #endif
    }

    #if DEBUG
    /// Isolated experiment: warm a second X runtime without changing the visible
    /// page. It is never enabled in a production launch.
    private func startPrewarmProbe() {
        guard prewarmProbeView == nil, let runtime, let visible = webView,
              visible.url?.path == "/home", let url = URL(string: "https://x.com/home") else { return }
        guard let (configuration, host) = try? runtime.makeBrowserConfiguration() else { return }
        let alternate = WKWebView(frame: .zero, configuration: configuration)
        host?.attach(to: alternate)
        alternate.translatesAutoresizingMaskIntoConstraints = false
        alternate.isOpaque = true
        view.insertSubview(alternate, belowSubview: visible)
        NSLayoutConstraint.activate([
            alternate.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            alternate.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            alternate.topAnchor.constraint(equalTo: view.topAnchor),
            alternate.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        prewarmProbeView = alternate
        prewarmProbeHost = host
        NSLog("XTEND_PREWARM_PROBE: second WebView created")
        alternate.load(URLRequest(url: url))
        for delay in [4.0, 9.0, 16.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak alternate] in
                guard let alternate else { return }
                let script = """
                (() => {
                  const lists = [...document.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')];
                  const list = lists.find(x => x.querySelectorAll('[role="tab"]').length >= 2);
                  const tabs = list?.querySelectorAll('[role="tab"]');
                  if (!tabs) return {state:'waiting', url:location.pathname};
                  if (tabs[1].getAttribute('aria-selected') !== 'true') tabs[1].click();
                  return {state:'following-clicked', url:location.pathname,
                    selected:tabs[1].getAttribute('aria-selected'),
                    cells:document.querySelectorAll('[data-testid="cellInnerDiv"]').length};
                })()
                """
                alternate.evaluateJavaScript(script) { result, error in
                    NSLog("XTEND_PREWARM_PROBE: after %.0fs result=%@ error=%@", delay,
                          String(describing: result), String(describing: error))
                }
            }
        }
    }
    #endif

    private func configure(_ webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func installSettingsMenu(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        let world = WKContentWorld.world(name: "Xtend.Settings")
        controller.add(SettingsMenuBridge(browser: self), contentWorld: world, name: "xtendSettings")
        #if DEBUG
        let forceTip = ProcessInfo.processInfo.arguments.contains("--xtend-test-show-settings-tip")
        #else
        let forceTip = false
        #endif
        let showTip = forceTip || !UserDefaults.standard.bool(forKey: Self.settingsTipSeenKey)
        controller.addUserScript(WKUserScript(
            source: "const __xtendShowSettingsTip = \(showTip ? "true" : "false");\n" + Self.settingsMenuScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
    }

    fileprivate func handleSettingsMessage(_ message: WKScriptMessage) {
        guard message.webView === webView,
              message.frameInfo.isMainFrame,
              ["x.com", "twitter.com"].contains(message.frameInfo.securityOrigin.host),
              let command = message.body as? [String: Any],
              let action = command["action"] as? String else { return }
        switch action {
        case "open":
            guard presentedViewController == nil else { return }
            openSettings()
        case "login":
            guard let visible = command["visible"] as? Bool else { return }
            settingsButton?.isHidden = !pageLoadFailed && !visible
        case "walkthroughDone":
            UserDefaults.standard.set(true, forKey: Self.settingsTipSeenKey)
        default:
            break
        }
    }

    private static let settingsMenuScript = #"""
    (() => {
      if (!['x.com', 'twitter.com'].includes(location.hostname)) return;
      const bridge = window.webkit?.messageHandlers?.xtendSettings;
      if (!bridge) return;
      const entryID = 'xtend-native-settings-entry';
      const tipID = 'xtend-settings-tip';
      let tipCompleted = !__xtendShowSettingsTip;
      const loginPaths = ['/i/flow/login', '/i/flow/signup', '/i/flow/password_reset', '/login', '/signup', '/account/access'];
      let lastLogin = null;
      let queued = false;

      function loginVisible() {
        const path = location.pathname;
        if (loginPaths.some(p => path === p || path.startsWith(p + '/'))) return true;
        // X can show a signed-out landing page without navigating to /login.
        return path === '/' &&
          !document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"]') &&
          !!document.querySelector('a[href="/i/flow/login"], a[href="/login"], [data-testid="loginButton"]');
      }

      function findDrawer() {
        if (innerWidth > 600) return null;
        const toggle = document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"][aria-expanded="true"]');
        if (!toggle || !toggle.getBoundingClientRect().width) return null;
        return [...document.querySelectorAll('[role="dialog"]')].find(panel => {
          const r = panel.getBoundingClientRect();
          return r.width > 160 && r.width < innerWidth && r.height >= innerHeight * .8 && r.left < 12 && !!panel.querySelector('a[href]');
        }) || null;
      }

      function insertSettings(drawer) {
        if (drawer.querySelector('#' + entryID)) return;
        const row = document.createElement('div');
        row.id = entryID;
        // Keep the footer on screen even when X's navigation links scroll.
        row.style.cssText = 'position:absolute;left:0;right:0;bottom:max(64px,env(safe-area-inset-bottom));z-index:10;border-top:1px solid rgba(128,128,128,.25);background:Canvas;color:CanvasText;';
        const button = document.createElement('button');
        button.type = 'button';
        button.setAttribute('aria-label', 'Xtendの設定');
        button.style.cssText = 'box-sizing:border-box;display:flex;align-items:center;gap:16px;width:100%;min-height:52px;padding:12px 16px;border:0;background:transparent;color:inherit;font:700 20px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;text-align:left;cursor:pointer;';
        const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        icon.setAttribute('viewBox', '0 0 24 24');
        icon.setAttribute('width', '23');
        icon.setAttribute('height', '23');
        icon.setAttribute('fill', 'none');
        icon.setAttribute('stroke', 'currentColor');
        icon.setAttribute('stroke-width', '2');
        icon.setAttribute('stroke-linecap', 'round');
        icon.setAttribute('stroke-linejoin', 'round');
        for (const d of ['M4 7h16', 'M4 17h16', 'M8 4v6', 'M16 14v6']) {
          const line = document.createElementNS('http://www.w3.org/2000/svg', 'path');
          line.setAttribute('d', d);
          icon.appendChild(line);
        }
        button.append(icon, document.createTextNode('Xtendの設定'));
        button.addEventListener('click', e => {
          e.preventDefault();
          e.stopPropagation();
          completeTip();
          bridge.postMessage({ action: 'open' });
        });
        row.appendChild(button);
        drawer.appendChild(row);
      }


      let hasShownMenuTarget = false;
      let lastDrawer = null;

      function completeTip() {
        if (tipCompleted) return;
        tipCompleted = true;
        document.getElementById(tipID)?.remove();
        bridge.postMessage({ action: 'walkthroughDone' });
      }

      function hideTip() {
        document.getElementById(tipID)?.remove();
      }

      function drawSpotlight(target, step) {
        const r = target.getBoundingClientRect();
        if (r.width < 20 || r.height < 20) { hideTip(); return; }
        let tip = document.getElementById(tipID);
        if (!tip) {
          tip = document.createElement('div');
          tip.id = tipID;
          tip.style.cssText = 'position:fixed;inset:0;z-index:2147483000;pointer-events:none;font:600 14px -apple-system,BlinkMacSystemFont,sans-serif;';
          const focus = document.createElement('div');
          focus.dataset.xtendFocus = '';
          focus.style.cssText = 'position:absolute;box-sizing:border-box;border:2px solid #6bd6ff;border-radius:14px;box-shadow:0 0 0 9999px rgba(0,0,0,.60),0 0 0 4px rgba(107,214,255,.22);pointer-events:none;';
          tip.appendChild(focus);
          document.body.appendChild(tip);
        }
        const focus = tip.querySelector('[data-xtend-focus]');
        const pad = step === 'menu' ? 3 : 5;
        focus.style.left = Math.max(2, r.left - pad) + 'px';
        focus.style.top = Math.max(2, r.top - pad) + 'px';
        focus.style.width = (r.width + pad * 2) + 'px';
        focus.style.height = (r.height + pad * 2) + 'px';
        focus.style.borderRadius = (step === 'menu' ? 12 : Math.ceil(r.height / 2 + pad)) + 'px';

        let note = tip.querySelector('[data-xtend-note]');
        if (step === 'avatar') {
          if (!note) {
            note = document.createElement('div');
            note.dataset.xtendNote = '';
            note.style.cssText = 'position:absolute;display:flex;align-items:center;gap:10px;border-radius:18px;padding:7px 8px 7px 12px;background:#fff;color:#111;box-shadow:0 3px 14px #0003;pointer-events:auto;';
            const text = document.createElement('span');
            text.textContent = '← 設定';
            const close = document.createElement('button');
            close.type = 'button';
            close.textContent = '×';
            close.setAttribute('aria-label', '案内を閉じる');
            close.style.cssText = 'background:transparent;border:0;color:#666;font:22px -apple-system,sans-serif;width:30px;height:30px;padding:0;cursor:pointer;';
            close.addEventListener('click', completeTip);
            note.append(text, close);
            tip.appendChild(note);
          }
          const left = Math.min(r.right + 12, innerWidth - 118);
          note.style.left = Math.max(8, left) + 'px';
          note.style.top = Math.max(8, r.top + r.height / 2 - 22) + 'px';
        } else {
          note?.remove();
        }
      }

      function updateTip(drawer) {
        if (tipCompleted) { hideTip(); return; }
        if (hasShownMenuTarget && !drawer) { completeTip(); return; }
        if (drawer) {
          const button = drawer.querySelector('#' + entryID + ' button');
          if (!button) { hideTip(); return; }
          hasShownMenuTarget = true;
          drawSpotlight(button, 'menu');
          return;
        }
        const toggle = document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"]');
        const composer = [...document.querySelectorAll('[role="dialog"]')].some(el => {
          const rect = el.getBoundingClientRect();
          return rect.width > 100 && rect.height > 100;
        });
        const visible = location.pathname === '/home' && !composer &&
          !!toggle && toggle.getAttribute('aria-expanded') === 'false' &&
          toggle.getBoundingClientRect().width > 0;
        if (!visible) { hideTip(); return; }
        drawSpotlight(toggle, 'avatar');
      }

      function sync() {
        const visible = loginVisible();
        if (visible !== lastLogin) {
          lastLogin = visible;
          bridge.postMessage({ action: 'login', visible });
        }
        const drawer = findDrawer();
        if (drawer) insertSettings(drawer);
        // Reposition the highlight after X's drawer slide animation finishes.
        if (drawer && drawer !== lastDrawer && !tipCompleted) setTimeout(schedule, 350);
        lastDrawer = drawer;
        updateTip(drawer);
      }
      function schedule() {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; sync(); });
      }
      new MutationObserver(schedule).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['aria-expanded']
      });
      schedule();
    })();
    """#

    private func installSettingsButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "slider.horizontal.3")
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = .systemBackground.withAlphaComponent(0.92)
        configuration.cornerStyle = .capsule

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Xtendの拡張機能設定"
        button.isHidden = true
        settingsButton = button
        button.layer.shadowOpacity = 0.16
        button.layer.shadowRadius = 6
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.widthAnchor.constraint(equalToConstant: 42),
            button.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    private func installBackButton() {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "arrow.left")
        config.baseForegroundColor = .label
        config.baseBackgroundColor = .systemBackground.withAlphaComponent(0.92)
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "前のページへ戻る"
        button.isHidden = true
        navigationBackButton = button
        button.addTarget(self, action: #selector(goBackToLogin), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.widthAnchor.constraint(equalToConstant: 42),
            button.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    @objc
    private func goBackToLogin() {
        guard let webView else { return }
        if webView.canGoBack {
            webView.goBack()
        } else if let login = URL(string: "https://x.com/i/flow/login") {
            webView.load(URLRequest(url: login))
        }
    }

    @objc
    private func openSettings() {
        let settings = ExtensionSettingsViewController(
            onReload: { [weak self] in
                self?.dismiss(animated: true) { [weak self] in
                    self?.applyExtensionChanges(force: true)
                }
            },
            onChange: { [weak self] in self?.markExtensionConfigurationChanged() },
            onFinish: { [weak self] in self?.applyExtensionChanges() }
        )
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        navigation.presentationController?.delegate = self
        present(navigation, animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        applyExtensionChanges()
    }

    func markExtensionConfigurationChanged() {
        pendingExtensionChanges = true
    }

    func applyExtensionChanges(force: Bool = false) {
        guard pendingExtensionChanges || force, let browser = webView else { return }
        pendingExtensionChanges = false
        // Installed content scripts belong to the WebView configuration.
        // Rebuild only when the extension package changes (or on explicit retry).
        buildBrowser(browser.url ?? URL(string: "https://x.com/home")!)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Explicit outbound links belong in the system browser. Keep
        // non-user-initiated HTTPS redirects inside WebKit for X sign-in flows.
        if navigationAction.targetFrame?.isMainFrame == true,
           url.scheme == "https",
           !isXURL(url),
           navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if url.scheme == "https" || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }

        // Native app handoff would lose the persistent WebKit X session.
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }

        if isXURL(url) {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageLoadFailed = false
        updateNavigationControls(for: webView)
        updateSettingsButton(for: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoadFailed = false
        updateNavigationControls(for: webView)
        updateSettingsButton(for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        let now = Date()
        if let previous = lastWebProcessTermination, now.timeIntervalSince(previous) < 30 {
            // A repeating WebContent crash must not turn into an endless reload loop.
            pageLoadFailed = true
            updateSettingsButton(for: webView)
            showNavigationError("Webページが繰り返し終了しました。", in: webView)
        } else {
            lastWebProcessTermination = now
            webView.reload()
        }
    }

    private func reportNavigationFailure(_ error: Error, in webView: WKWebView) {
        guard self.webView === webView,
              (error as NSError).code != NSURLErrorCancelled else { return }
        pageLoadFailed = true
        updateSettingsButton(for: webView)
        showNavigationError(error.localizedDescription, in: webView)
    }

    private func showNavigationError(_ message: String, in webView: WKWebView) {
        guard !isShowingNavigationError, presentedViewController == nil else { return }
        isShowingNavigationError = true
        let alert = UIAlertController(
            title: "Xのページを読み込めませんでした",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "閉じる", style: .cancel) { [weak self] _ in
            self?.isShowingNavigationError = false
        })
        alert.addAction(UIAlertAction(title: "再試行", style: .default) { [weak self, weak webView] _ in
            guard let self, let webView else { return }
            self.isShowingNavigationError = false
            self.lastWebProcessTermination = nil
            webView.reload()
        })
        present(alert, animated: true)
    }


    private func updateSettingsButton(for webView: WKWebView, url: URL? = nil) {
        let currentURL = url ?? webView.url
        let path = currentURL?.path ?? ""
        let loginPaths = ["/i/flow/login", "/i/flow/signup", "/i/flow/password_reset", "/login", "/signup", "/account/access"]
        let isLogin = isXURL(currentURL) && loginPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        settingsButton?.isHidden = !pageLoadFailed && !isLogin
    }

    private func updateNavigationControls(for webView: WKWebView, url: URL? = nil) {
        let onX = isXURL(url ?? webView.url)
        navigationBackButton?.isHidden = onX
        // X has its own back controls and left drawer. Never run WebKit's
        // competing edge-back recognizer over X's touch-driven navigation.
        webView.allowsBackForwardNavigationGestures = !onX
    }

    private func isXURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "x.com" || host == "twitter.com"
    }

    private func showFatalError(_ error: Error) {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "アプリを起動できませんでした。\n\n\(error.localizedDescription)"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func showTransientError(_ error: Error) {
        let alert = UIAlertController(
            title: "設定を開けませんでした",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

@MainActor
private final class SettingsMenuBridge: NSObject, WKScriptMessageHandler {
    weak var browser: BrowserViewController?

    init(browser: BrowserViewController) {
        self.browser = browser
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        browser?.handleSettingsMessage(message)
    }
}