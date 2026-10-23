import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let initialURL: URL?
    private var runtime: ExtensionRuntime?
    private var extensionHost: ExtensionHost?
    private var webView: WKWebView?
    private weak var navigationBackButton: UIButton?
    private var pendingExtensionChanges = false
    private var hasShownExtensionWarning = false
    private struct ReadingPosition {
        let scrollY: Double
        let postPath: String?
        let postTop: Double?
    }

    private var pendingRestoration: (webView: WKWebView, position: ReadingPosition)?
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
            case ExtensionPackage.swipeNavigationID: "X Swipe Navigation"
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

    private func buildBrowser(_ url: URL, restoring position: ReadingPosition? = nil) {
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
            configuration = fallback
            host = nil
            runtimeError = error.localizedDescription
            hasShownExtensionWarning = false
        }
        let browser = WKWebView(frame: .zero, configuration: configuration)
        host?.attach(to: browser)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        self.runtime = runtime
        self.extensionHost = host
        self.webView = browser
        configure(browser)
        view.sendSubviewToBack(browser)
        if let position,
           (position.scrollY > 0 || position.postPath != nil),
           canRestoreReadingPosition(at: url) {
            pendingRestoration = (browser, position)
        } else {
            pendingRestoration = nil
        }
        browser.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
    }

    private func configure(_ webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
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

    private func installSettingsButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "slider.horizontal.3")
        configuration.baseForegroundColor = .label
        configuration.baseBackgroundColor = .systemBackground.withAlphaComponent(0.92)
        configuration.cornerStyle = .capsule

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Xtendの拡張機能設定"
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
            onChange: { [weak self] in self?.pendingExtensionChanges = true },
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

    private func applyExtensionChanges(force: Bool = false) {
        guard pendingExtensionChanges || force, let old = webView else { return }
        pendingExtensionChanges = false
        let url = old.url ?? URL(string: "https://x.com/home")!
        // X can scroll its native WKScrollView while document.scrollingElement
        // reports zero. Never prefer a zero JavaScript result to a real offset.
        let nativeY = max(0, Double(old.scrollView.contentOffset.y))
        let capture = """
        (() => {
          const y = Number(window.scrollY || document.scrollingElement?.scrollTop || 0);
          const article = [...document.querySelectorAll('article[data-testid="tweet"]')]
            .find(node => {
              const rect = node.getBoundingClientRect();
              return rect.bottom > 120 && rect.top < Math.min(window.innerHeight, 600);
            });
          const link = article?.querySelector('a[href*="/status/"]');
          return {
            y: Number.isFinite(y) ? y : 0,
            postPath: link?.getAttribute('href') ?? null,
            postTop: article?.getBoundingClientRect().top ?? null
          };
        })();
        """
        old.evaluateJavaScript(capture) { [weak self, weak old] result, _ in
            Task { @MainActor [weak self, weak old] in
                guard let self, let old, self.webView === old else { return }
                let values = result as? [String: Any] ?? [:]
                let scriptY = (values["y"] as? NSNumber)?.doubleValue ?? 0
                let y = max(nativeY, scriptY.isFinite ? scriptY : 0)
                let position = ReadingPosition(
                    scrollY: y,
                    postPath: values["postPath"] as? String,
                    postTop: (values["postTop"] as? NSNumber)?.doubleValue
                )
                self.buildBrowser(url, restoring: position)
            }
        }
    }

    private func restoreReadingPosition(in browser: WKWebView, attempt: Int) {
        guard webView === browser, let state = pendingRestoration,
              state.webView === browser, attempt <= 6 else { return }
        if browser.scrollView.isDragging || browser.scrollView.isDecelerating {
            pendingRestoration = nil // Never fight a new user gesture.
            return
        }
        let position = state.position
        let pathLiteral = (try? JSONEncoder().encode(position.postPath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let targetTop = position.postTop ?? 120
        let script = """
        (() => {
          const targetPath = \(pathLiteral);
          const targetTop = \(targetTop);
          let found = false;
          if (targetPath) {
            const link = [...document.querySelectorAll('a[href*="/status/"]')]
              .find(node => node.getAttribute('href') === targetPath);
            const article = link?.closest('article');
            if (article) {
              window.scrollBy(0, article.getBoundingClientRect().top - targetTop);
              found = true;
            }
          }
          if (!found) window.scrollTo(0, \(position.scrollY));
          return {
            y: Number(window.scrollY || document.scrollingElement?.scrollTop || 0),
            anchorFound: found
          };
        })();
        """
        browser.evaluateJavaScript(script) { [weak self, weak browser] result, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser, self.webView === browser else { return }
                // WebKit's native scroll offset is needed for sites whose DOM
                // root does not own the scroll container.
                let scriptY = ((result as? [String: Any])?["y"] as? NSNumber)?.doubleValue ?? 0
                let anchorFound = ((result as? [String: Any])?["anchorFound"] as? Bool) ?? false
                if !anchorFound && scriptY < position.scrollY - 30,
                   browser.scrollView.contentSize.height > browser.scrollView.bounds.height {
                    let maxY = max(0, browser.scrollView.contentSize.height - browser.scrollView.bounds.height)
                    browser.scrollView.setContentOffset(
                        CGPoint(x: 0, y: min(position.scrollY, maxY)), animated: false
                    )
                }
                if attempt == 6 {
                    self.pendingRestoration = nil
                } else {
                    let delay = 0.5 + Double(attempt - 1) * 0.3
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak browser] in
                        guard let self, let browser else { return }
                        self.restoreReadingPosition(in: browser, attempt: attempt + 1)
                    }
                }
            }
        }
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
        navigationBackButton?.isHidden = isXURL(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationBackButton?.isHidden = isXURL(webView.url)
        if let state = pendingRestoration, state.webView === webView {
            if canRestoreReadingPosition(at: webView.url) {
                restoreReadingPosition(in: webView, attempt: 1)
            } else {
                pendingRestoration = nil
            }
        }
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
            showNavigationError("Webページが繰り返し終了しました。", in: webView)
        } else {
            lastWebProcessTermination = now
            webView.reload()
        }
    }

    private func reportNavigationFailure(_ error: Error, in webView: WKWebView) {
        guard self.webView === webView,
              (error as NSError).code != NSURLErrorCancelled else { return }
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


    private func canRestoreReadingPosition(at url: URL?) -> Bool {
        guard isXURL(url), let path = url?.path else { return false }
        return !path.hasPrefix("/i/flow/login") &&
               !path.hasPrefix("/login") &&
               !path.hasPrefix("/account/login")
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