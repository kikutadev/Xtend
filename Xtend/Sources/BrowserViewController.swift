import UIKit
import WebKit

enum BetaTimelinePreferences {
    static let key = "xtend.beta.timelinePreload"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

@MainActor
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let initialURL: URL?
    private var runtime: ExtensionRuntime?
    private var extensionHost: ExtensionHost?
    private var webView: WKWebView?
    private var standbyView: WKWebView?
    private var standbyHost: ExtensionHost?
    private var standbyTarget: Int?
    private var standbyReady = false
    private var visibleTab: Int?
    private var warmupScheduled = false
    private var visibleURLObservation: NSKeyValueObservation?
    private var preloadSuspended = false
    #if DEBUG
    private var benchmarkScheduled = false
    private var benchmarkRunning = false
    #endif
    private var preloadEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--xtend-test-beta-preload") { return true }
        #endif
        return BetaTimelinePreferences.enabled
    }
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
        NotificationCenter.default.addObserver(self, selector: #selector(suspendPreload),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(releasePreloadInBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumePreload),
            name: UIApplication.didBecomeActiveNotification, object: nil)
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
        releasePreload()
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
        installBetaBridge(into: configuration)
        let browser = WKWebView(frame: .zero, configuration: configuration)
        browser.accessibilityIdentifier = "Xtend.ActiveTimelineWebView"
        host?.attach(to: browser)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        self.runtime = runtime
        self.extensionHost = host
        self.webView = browser
        observeVisibleURL()
        configure(browser)
        updateNavigationControls(for: browser, url: url)
        view.sendSubviewToBack(browser)
        browser.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
        #if DEBUG
        NSLog("XTEND_BETA: build enabled=%@", String(preloadEnabled))
        #endif
        if preloadEnabled { schedulePreload() }
    }

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

    fileprivate func handleBetaTabMessage(_ message: WKScriptMessage) {
        guard message.name == "xtendBetaTab", message.webView === webView,
              message.frameInfo.isMainFrame,
              ["x.com", "twitter.com"].contains(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any],
              body["action"] as? String == "switch",
              let target = body["target"] as? Int, target == 0 || target == 1 else { return }
        #if DEBUG
        NSLog("XTEND_BETA: bridge requested tab=%ld", target)
        #endif
        swapPreloadedTab(target)
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
            onFinish: { [weak self] in
                self?.applyExtensionChanges()
                self?.applyPreloadSetting()
            }
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
        applyPreloadSetting()
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
        if standbyView === webView {
            standbyReady = false
            setBetaBridge(false, in: self.webView)
            return
        }
        guard self.webView === webView else { return }
        if webView.url?.path != "/home" { releasePreload() }
        pageLoadFailed = false
        updateNavigationControls(for: webView)
        updateSettingsButton(for: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if standbyView === webView {
            checkStandbyReady(webView)
            return
        }
        guard self.webView === webView else { return }
        pageLoadFailed = false
        updateNavigationControls(for: webView)
        updateSettingsButton(for: webView)
        schedulePreload()
        #if DEBUG
        schedulePageViewBenchmark()
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if standbyView === webView {
            preloadSuspended = true
            releasePreload()
            return
        }
        guard self.webView === webView else { return }
        releasePreload()
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
        if standbyView === webView {
            // WebKit can cancel an intermediate provisional navigation normally.
            if (error as NSError).code != NSURLErrorCancelled { releasePreload() }
            return
        }
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
// Keeping all beta lifecycle transitions together makes the normal browser
// controller independent of its optional second WebView.
private extension BrowserViewController {
    private func installBetaBridge(into configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(BetaTabMessageBridge(owner: self),
            contentWorld: WKContentWorld.world(name: "Xtend.Navigation"), name: "xtendBetaTab")
    }

    private func setBetaBridge(_ enabled: Bool, in browser: WKWebView?) {
        guard let browser else { return }
        browser.evaluateJavaScript("window.__xtendBetaTabReady = \(enabled ? "true" : "false")",
            in: nil, in: WKContentWorld.world(name: "Xtend.Navigation"), completionHandler: nil)
    }

    /// Close X overlays only in the offscreen WebView. Never dismiss UI that
    /// the user intentionally opened on the visible timeline.
    private static let clearStandbyOverlays = """
        (() => {
          const drawer = document.querySelector('button[data-testid="DashButton_ProfileIcon_Link"][aria-expanded="true"]');
          if (drawer) { drawer.click(); return false; }
          const shortcut = [...document.querySelectorAll('[aria-label="Close"]')]
            .find(button => {
              const rect=button.getBoundingClientRect();
              return rect.width > 0 && rect.bottom > innerHeight * .75 && rect.right > innerWidth * .5;
            });
          if (shortcut) { shortcut.click(); return false; }
          return true;
        })()
        """

    private static let selectedTabScript = """
        (() => {
          const list = [...document.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')]
            .find(el => { const r=el.getBoundingClientRect(); return r.width>=80 && r.top>=-10 && r.top<=160 && el.querySelectorAll('[role="tab"]').length>=2; });
          const tabs=list?.querySelectorAll('[role="tab"]');
          if (!tabs) return -1;
          return [0,1].find(i=>tabs[i]?.getAttribute('aria-selected')==='true') ?? -1;
        })()
        """

    private func schedulePreload(attempt: Int = 0) {
        #if DEBUG
        NSLog("XTEND_BETA: schedule enabled=%@ suspended=%@ standby=%@", String(preloadEnabled), String(preloadSuspended), String(standbyView != nil))
        #endif
        guard preloadEnabled, !preloadSuspended, standbyView == nil, !warmupScheduled,
              UIApplication.shared.applicationState == .active,
              webView?.url?.path == "/home" else { return }
        warmupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.warmupScheduled = false
            guard self.preloadEnabled, !self.preloadSuspended, self.standbyView == nil,
                  UIApplication.shared.applicationState == .active,
                  let browser = self.webView, browser.url?.path == "/home", self.presentedViewController == nil else { return }
            browser.evaluateJavaScript(Self.selectedTabScript) { [weak self, weak browser] result, error in
                #if DEBUG
                NSLog("XTEND_BETA: selected tab=%@ error=%@", String(describing: result), String(describing: error))
                #endif
                guard let self, let browser, self.webView === browser else { return }
                if let selected = result as? Int, selected == 0 || selected == 1 {
                    self.startPreload(oppositeOf: selected)
                } else if attempt < 10 {
                    // X hydrates its tab bar asynchronously, often after didFinish.
                    self.schedulePreload(attempt: attempt + 1)
                }
            }
        }
    }

    private func startPreload(oppositeOf selected: Int) {
        #if DEBUG
        NSLog("XTEND_BETA: preload selected=%ld", selected)
        #endif
        guard preloadEnabled, !preloadSuspended, standbyView == nil,
              UIApplication.shared.applicationState == .active,
              let runtime, let browser = webView, browser.url?.path == "/home",
              let (config, host) = try? runtime.makeBrowserConfiguration() else { return }
        installSettingsMenu(into: config)
        installBetaBridge(into: config)
        let alternate = WKWebView(frame: .zero, configuration: config)
        alternate.accessibilityIdentifier = "Xtend.StandbyTimelineWebView"
        alternate.accessibilityElementsHidden = true
        alternate.isUserInteractionEnabled = false
        alternate.navigationDelegate = self
        alternate.uiDelegate = self
        host?.attach(to: alternate)
        alternate.translatesAutoresizingMaskIntoConstraints = false
        alternate.scrollView.contentInsetAdjustmentBehavior = .automatic
        alternate.isOpaque = false
        alternate.backgroundColor = .systemBackground
        view.insertSubview(alternate, belowSubview: browser)
        NSLayoutConstraint.activate([
            alternate.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            alternate.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            alternate.topAnchor.constraint(equalTo: view.topAnchor),
            alternate.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        visibleTab = selected
        standbyTarget = 1 - selected
        standbyReady = false
        standbyHost = host
        standbyView = alternate
        alternate.load(URLRequest(url: URL(string: "https://x.com/home")!))
    }

    private func checkStandbyReady(_ browser: WKWebView, attempts: Int = 0) {
        guard standbyView === browser, let target = standbyTarget, preloadEnabled,
              !preloadSuspended, webView?.url?.path == "/home" else { return }
        // X hydrates its tabs after WKNavigationDelegate.didFinish.
        let choose = """
        (() => {
          const list = [...document.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')]
            .find(el=>el.querySelectorAll('[role="tab"]').length >= 2);
          const tabs=list?.querySelectorAll('[role="tab"]');
          if (!tabs) return -1;
          if (tabs[\(target)].getAttribute('aria-selected') !== 'true') {
            tabs[\(target)].click();
            return 0;
          }
          // Cells can be placeholders. A real rendered post is required before
          // exchanging WebViews, otherwise the beta can expose a loading feed.
          const posts = document.querySelectorAll('[data-testid="tweet"], [data-testid="tweetText"]');
          return posts.length > 0 && tabs[\(target)].getAttribute('aria-selected') === 'true' ? 1 : 0;
        })()
        """
        browser.evaluateJavaScript(choose) { [weak self, weak browser] result, _ in
            guard let self, let browser, self.standbyView === browser else { return }
            if (result as? Int) == 1 {
                browser.evaluateJavaScript(Self.clearStandbyOverlays) { [weak self, weak browser] clean, _ in
                    guard let self, let browser, self.standbyView === browser else { return }
                    if (clean as? Bool) != true {
                        if attempts < 12 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak browser] in
                                guard let self, let browser else { return }
                                self.checkStandbyReady(browser, attempts: attempts + 1)
                            }
                        } else { self.releasePreload() }
                        return
                    }
                    self.finishStandbyPreparation(browser, target: target)
                }
            } else if attempts < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak browser] in
                    guard let self, let browser else { return }
                    self.checkStandbyReady(browser, attempts: attempts + 1)
                }
            } else { self.releasePreload() }
        }
    }

    private func finishStandbyPreparation(_ browser: WKWebView, target: Int) {
        guard standbyView === browser, standbyTarget == target else { return }
        #if DEBUG
        NSLog("XTEND_BETA: standby ready target=%ld", target)
        #endif
        standbyReady = true
        #if DEBUG
        schedulePageViewBenchmark()
        #endif
        setBetaBridge(true, in: webView)
        setBetaBridge(true, in: browser)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--xtend-test-beta-swap") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.swapPreloadedTab(target)
            }
        }
        #endif
    }

    private func swapPreloadedTab(_ target: Int, attempts: Int = 0) {
        #if DEBUG
        NSLog("XTEND_BETA: swap request=%ld visible=%@ standby=%@", target, String(describing: visibleTab), String(describing: standbyTarget))
        #endif
        guard preloadEnabled, !preloadSuspended, standbyReady,
              let old = webView, let next = standbyView,
              old.url?.path == "/home", next.url?.path == "/home",
              standbyTarget == target, visibleTab == 1 - target else {
            if let browser = webView { clickOriginalXTab(target, in: browser) }
            return
        }
        // If X changed tabs on its own (e.g. another extension), don't swap
        // stale feeds. Fall back to X and discard the stale standby.
        old.evaluateJavaScript(Self.selectedTabScript) { [weak self, weak old, weak next] result, _ in
            guard let self, let old, let next,
                  self.webView === old, self.standbyView === next else { return }
            guard (result as? Int) == self.visibleTab else {
                // The visible X page may have changed tabs independently.
                // Don't swallow a gesture when the warm copy is stale.
                self.releasePreload()
                self.clickOriginalXTab(target, in: old)
                self.schedulePreload()
                return
            }
            next.evaluateJavaScript(Self.clearStandbyOverlays) { [weak self, weak old, weak next] clear, _ in
                guard let self, let old, let next, self.webView === old, self.standbyView === next else { return }
                if (clear as? Bool) != true {
                    if attempts >= 6 {
                        // An overlay that cannot close must not trap navigation.
                        self.preloadSuspended = true
                        self.releasePreload()
                        self.clickOriginalXTab(target, in: old)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            self?.swapPreloadedTab(target, attempts: attempts + 1)
                        }
                    }
                    return
                }
                self.completeTabSwap(from: old, to: next, target: target)
            }
        }
    }

    private func completeTabSwap(from old: WKWebView, to next: WKWebView, target: Int) {
        guard webView === old, standbyView === next else { return }
        #if DEBUG
        NSLog("XTEND_BETA: swap accepted to=%ld", target)
        if ProcessInfo.processInfo.arguments.contains("--xtend-test-beta-audit") {
            auditBetaWebView(old, stage: "leaving")
            auditBetaWebView(next, stage: "before-swap")
        }
        #endif
        view.insertSubview(next, aboveSubview: old)
        old.accessibilityIdentifier = "Xtend.StandbyTimelineWebView"
        old.accessibilityElementsHidden = true
        old.isUserInteractionEnabled = false
        next.accessibilityIdentifier = "Xtend.ActiveTimelineWebView"
        next.accessibilityElementsHidden = false
        next.isUserInteractionEnabled = true
        webView = next
        standbyView = old
        observeVisibleURL()
        swap(&extensionHost, &standbyHost)
        standbyTarget = 1 - target
        visibleTab = target
        standbyReady = true // The old visible page has already been rendered.
        updateNavigationControls(for: next)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--xtend-test-beta-audit") {
            auditBetaWebView(next, stage: "after-swap")
        }
        #endif
    }

    #if DEBUG
    /// Simulator-only, repeatable A/B of real X page-view latency. Never used
    /// for normal users. Only durations/counts are logged, not post contents.
    private func schedulePageViewBenchmark(attempt: Int = 0) {
        guard ProcessInfo.processInfo.arguments.contains("--xtend-benchmark-pageview"),
              !benchmarkRunning, !benchmarkScheduled, attempt < 40 else { return }
        benchmarkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 4.0 : 0.8)) { [weak self] in
            guard let self else { return }
            self.benchmarkScheduled = false
            guard let browser = self.webView, browser.url?.path == "/home",
                  (!self.preloadEnabled || self.standbyReady) else {
                self.schedulePageViewBenchmark(attempt: attempt + 1)
                return
            }
            browser.evaluateJavaScript(Self.selectedTabScript) { [weak self, weak browser] result, _ in
                guard let self, let browser, self.webView === browser else { return }
                guard let selected = result as? Int, selected == 0 || selected == 1 else {
                    self.schedulePageViewBenchmark(attempt: attempt + 1)
                    return
                }
                self.benchmarkRunning = true
                NSLog("XTEND_PAGEVIEW_BENCH start mode=%@ selected=%ld", self.preloadEnabled ? "warm" : "standard", selected)
                self.runPageViewBenchmark(target: 1 - selected, remaining: 10, samples: [])
            }
        }
    }

    private static let benchmarkXTabSwitch = """
      const list = [...document.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')]
        .find(e => e.querySelectorAll('[role="tab"]').length >= 2);
      const tabs = list?.querySelectorAll('[role="tab"]');
      if (!tabs || !tabs[target]) return {ok:false,reason:'no-tabs'};
      const signature = () => [...document.querySelectorAll('[data-testid="tweet"]')].slice(0,3)
        .map(e => (e.innerText || '').slice(0,180)).join('|');
      const prior = signature();
      const start = performance.now();
      tabs[target].click();
      const observation = await new Promise(resolve => {
        function poll() {
          const posts = document.querySelectorAll('[data-testid="tweet"]').length;
          const selected = tabs[target]?.getAttribute('aria-selected') === 'true';
          if (selected && posts > 0 && signature() !== prior) {
            requestAnimationFrame(() => requestAnimationFrame(() =>
              resolve({ok:true,domMs:performance.now()-start,posts})));
          } else if (performance.now()-start > 7000) {
            resolve({ok:false,reason:'timeout',posts,selected});
          } else { setTimeout(poll, 20); }
        }
        poll();
      });
      return observation;
      """

    private func runPageViewBenchmark(target: Int, remaining: Int, samples: [Double]) {
        guard remaining > 0 else {
            let ordered = samples.sorted()
            let median = ordered.isEmpty ? -1 : (ordered[(ordered.count-1)/2] + ordered[ordered.count/2])/2
            NSLog("XTEND_PAGEVIEW_BENCH summary mode=%@ valid=%ld medianMs=%.1f samples=%@",
                  preloadEnabled ? "warm" : "standard", samples.count, median, String(describing: samples))
            benchmarkRunning = false
            return
        }
        guard let browser = webView, browser.url?.path == "/home" else {
            NSLog("XTEND_PAGEVIEW_BENCH abort navigation")
            benchmarkRunning = false
            return
        }
        let started = CACurrentMediaTime()
        let finish: (Bool, Int) -> Void = { [weak self] valid, posts in
            guard let self, let current = self.webView else { return }
            guard valid else {
                NSLog("XTEND_PAGEVIEW_BENCH failed mode=%@ run=%ld", self.preloadEnabled ? "warm" : "standard", 11-remaining)
                self.benchmarkRunning = false
                return
            }
            current.takeSnapshot(with: nil) { [weak self] image, error in
                guard let self else { return }
                let duration = (CACurrentMediaTime() - started)*1000
                guard image != nil, error == nil else {
                    NSLog("XTEND_PAGEVIEW_BENCH failed snapshot run=%ld", 11-remaining)
                    self.benchmarkRunning = false
                    return
                }
                NSLog("XTEND_PAGEVIEW_BENCH sample mode=%@ run=%ld tab=%ld ms=%.1f posts=%ld",
                      self.preloadEnabled ? "warm" : "standard", 11-remaining, target, duration, posts)
                DispatchQueue.main.asyncAfter(deadline: .now()+0.55) { [weak self] in
                    self?.runPageViewBenchmark(target: 1-target, remaining: remaining-1, samples: samples+[duration])
                }
            }
        }
        if preloadEnabled {
            guard standbyReady, standbyTarget == target else {
                NSLog("XTEND_PAGEVIEW_BENCH failed standby not ready")
                benchmarkRunning = false
                return
            }
            let previous = browser
            swapPreloadedTab(target)
            func poll(_ tries: Int) {
                guard tries < 350 else { finish(false, 0); return }
                if let next = self.webView, next !== previous, self.visibleTab == target {
                    next.evaluateJavaScript("document.querySelectorAll('[data-testid=\"tweet\"]').length") { result, _ in
                        let posts = result as? Int ?? 0
                        finish(posts > 0, posts)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.02) { poll(tries+1) }
                }
            }
            poll(0)
        } else {
            browser.callAsyncJavaScript(Self.benchmarkXTabSwitch, arguments: ["target":target], in: nil,
                in: .page) { result in
                switch result {
                case .success(let value):
                    let outcome = value as? [String:Any] ?? [:]
                    finish((outcome["ok"] as? Bool) == true, outcome["posts"] as? Int ?? 0)
                case .failure(let error):
                    NSLog("XTEND_PAGEVIEW_BENCH JS error=%@", String(describing: error))
                    finish(false, 0)
                }
            }
        }
    }

    /// Reports DOM lifetime and rendered-post count, not post text or account data.
    /// A true warm switch keeps the same timeOrigin and populated DOM.
    private func auditBetaWebView(_ browser: WKWebView, stage: String) {
        let script = """
        (() => ({
          timeOrigin: performance.timeOrigin,
          path: location.pathname,
          selected: [...document.querySelectorAll('[role="tab"]')].findIndex(t => t.getAttribute('aria-selected') === 'true'),
          posts: document.querySelectorAll('[data-testid="tweet"], [data-testid="tweetText"]').length,
          cells: document.querySelectorAll('[data-testid="cellInnerDiv"]').length,
          scrollY: Math.round(window.scrollY),
          scrollTop: Math.round(document.scrollingElement?.scrollTop ?? 0),
          navigationEntries: performance.getEntriesByType('navigation').length,
          readyState: document.readyState
        }))()
        """
        browser.evaluateJavaScript(script) { result, error in
            NSLog("XTEND_BETA_AUDIT %@ %@ nativeScroll=%0.1f error=%@", stage,
                  String(describing: result), browser.scrollView.contentOffset.y, String(describing: error))
        }
        if stage == "after-swap" {
            // A snapshot validates that WebKit can paint the already hydrated
            // standby immediately after it becomes the frontmost page.
            browser.takeSnapshot(with: nil) { image, error in
                NSLog("XTEND_BETA_AUDIT snapshot visible=%@ size=%@ error=%@",
                      String(image != nil), String(describing: image?.size), String(describing: error))
            }
        }
    }
    #endif

    private func clickOriginalXTab(_ target: Int, in browser: WKWebView) {
        guard browser.url?.path == "/home", target == 0 || target == 1 else { return }
        let script = """
        (() => {
            const list=[...document.querySelectorAll('[data-testid="ScrollSnap-List"][role="tablist"]')]
                .find(el=>el.querySelectorAll('[role="tab"]').length>=2);
            list?.querySelectorAll('[role="tab"]')[\(target)]?.click();
        })()
        """
        browser.evaluateJavaScript(script, in: nil, in: WKContentWorld.world(name: "Xtend.Navigation"), completionHandler: nil)
    }

    private func observeVisibleURL() {
        visibleURLObservation = webView?.observe(\.url, options: [.new]) { [weak self] browser, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.webView === browser else { return }
                if browser.url?.path == "/home" { self.schedulePreload() }
                else { self.releasePreload() }
            }
        }
    }

    private func releasePreload() {
        warmupScheduled = false
        standbyReady = false
        setBetaBridge(false, in: webView)
        setBetaBridge(false, in: standbyView)
        standbyView?.stopLoading()
        standbyView?.navigationDelegate = nil
        standbyView?.uiDelegate = nil
        standbyView?.removeFromSuperview()
        standbyView = nil
        standbyHost = nil
        standbyTarget = nil
        visibleTab = nil
    }

    @objc private func suspendPreload() {
        #if DEBUG
        NSLog("XTEND_BETA: memory warning, suspending")
        #endif
        preloadSuspended = true
        releasePreload()
    }

    @objc private func releasePreloadInBackground() {
        // A pending asynchronous warm-up must not recreate WebKit in background.
        releasePreload()
    }

    @objc private func resumePreload() { schedulePreload() }

    private func applyPreloadSetting() {
        preloadSuspended = false
        if preloadEnabled { schedulePreload() }
        else { releasePreload() }
    }

}

/// WKUserContentController retains its handlers. Do not retain the browser
/// controller from both the active and the standby page's configurations.
@MainActor
private final class BetaTabMessageBridge: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?

    init(owner: BrowserViewController) { self.owner = owner }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleBetaTabMessage(message)
    }
}
