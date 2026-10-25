import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let initialURL: URL?
    private var runtime: ExtensionRuntime?
    private var extensionHost: ExtensionHost?
    private var webView: WKWebView?
    private var pageURLObservation: NSKeyValueObservation?
    private weak var historyBackGesture: UIScreenEdgePanGestureRecognizer?
    private weak var historyForwardGesture: UIScreenEdgePanGestureRecognizer?
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
        pageURLObservation = nil
        historyBackGesture = nil
        historyForwardGesture = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        self.runtime = runtime
        self.extensionHost = host
        self.webView = browser
        configure(browser)
        installHistoryGestures(on: browser)
        updateNavigationControls(for: browser, url: url)
        // X changes routes with the History API without a document navigation.
        // Observe the effective URL so edge gestures switch on SPA transitions.
        pageURLObservation = browser.observe(\.url, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async { [weak self, weak observed] in
                guard let self, let observed, self.webView === observed else { return }
                self.updateNavigationControls(for: observed)
            }
        }
        view.sendSubviewToBack(browser)
        browser.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
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

    private func installHistoryGestures(on browser: WKWebView) {
        let back = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleHistoryEdge(_:)))
        back.edges = .left
        back.name = "xtend.history.back"
        browser.addGestureRecognizer(back)
        historyBackGesture = back

        let forward = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleHistoryEdge(_:)))
        forward.edges = .right
        forward.name = "xtend.history.forward"
        browser.addGestureRecognizer(forward)
        historyForwardGesture = forward
    }

    @objc
    private func handleHistoryEdge(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended,
              let browser = webView, gesture.view === browser else { return }
        let movement = gesture.translation(in: browser)
        guard abs(movement.x) >= 64, abs(movement.x) > abs(movement.y) * 1.4 else { return }
        if gesture.edges == .left, movement.x > 0, browser.canGoBack {
            browser.goBack()
        } else if gesture.edges == .right, movement.x < 0, browser.canGoForward {
            browser.goForward()
        }
    }

    private func installSettingsMenu(into configuration: WKWebViewConfiguration) {
        #if DEBUG
        let forceTip = ProcessInfo.processInfo.arguments.contains("--xtend-test-show-settings-tip")
        #else
        let forceTip = false
        #endif
        let showTip = forceTip || !UserDefaults.standard.bool(forKey: Self.settingsTipSeenKey)
        do {
            try XtendSettingsMenu.install(into: configuration, showTip: showTip) { [weak self] message in
                self?.handleSettingsMessage(message)
            }
        } catch {
            runtimeError = error.localizedDescription
            hasShownExtensionWarning = false
        }
    }

    private func handleSettingsMessage(_ message: WKScriptMessage) {
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
            onPromoPreferencesChanged: { [weak self] in
                guard let webView = self?.webView else { return }
                XtendSettingsMenu.updatePreferences(in: webView)
            },
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
        guard self.webView === webView else { return }
        pageLoadFailed = false
        updateNavigationControls(for: webView)
        updateSettingsButton(for: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
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
        let currentURL = url ?? webView.url
        let onX = isXURL(currentURL)
        navigationBackButton?.isHidden = onX
        // On X home the leading edge belongs to the profile drawer. Other X
        // routes use explicit iOS edge pans: X's SPA can prevent WebKit's
        // built-in interactive history gestures from recognizing touches.
        let useXHistoryEdges = onX && currentURL?.path != "/home"
        historyBackGesture?.isEnabled = useXHistoryEdges
        historyForwardGesture?.isEnabled = useXHistoryEdges
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
