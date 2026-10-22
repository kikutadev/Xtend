import UIKit
import WebKit

@MainActor
final class BrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let initialURL: URL?
    private var runtime: ExtensionRuntime?
    private var extensionHost: ExtensionHost?
    private var webView: WKWebView?
    private weak var navigationBackButton: UIButton?

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        do {
            let runtime = try ExtensionRuntime()
            let (configuration, host) = try runtime.makeBrowserConfiguration()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            host?.attach(to: webView)

            self.runtime = runtime
            self.extensionHost = host
            self.webView = webView

            configure(webView)
            installSettingsButton()
            installBackButton()
            loadXHome()
        } catch {
            showFatalError(error)
        }
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

    private func loadXHome() {
        guard let webView, let url = initialURL ?? URL(string: "https://x.com/home") else { return }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
    }

    @objc
    private func openSettings() {
        let settings = ExtensionSettingsViewController { [weak self] in
            guard let self, let window = self.view.window else { return }
            let url = self.webView?.url
            self.dismiss(animated: true) {
                UIView.transition(with: window, duration: 0.22, options: .transitionCrossDissolve) {
                    window.rootViewController = BrowserViewController(initialURL: url)
                }
            }
        }
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
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
        guard isXURL(webView.url) else { return }
        #if DEBUG
        let probe = "document.documentElement.getAttribute('data-xff-cat-recovery-ready') || '0'"
        webView.evaluateJavaScript(probe) { [weak self] result, error in
            if let error {
                print("NYATTO_ACCEPTANCE probe_error=\(error.localizedDescription)")
            } else {
                print("NYATTO_ACCEPTANCE cat_recovery_ready=\(result ?? "nil")")
                self?.extensionHost?.runNyattoAcceptanceProbe()
                webView.evaluateJavaScript(
                    "typeof globalThis[Symbol.for('x-home-anchor.instance')]",
                    in: nil,
                    in: ExtensionPackage.contentWorld(for: ExtensionPackage.homeAnchorID)
                ) { result in
                    switch result {
                    case .success(let value):
                        print("X_HOME_ANCHOR_ACCEPTANCE installed=\(value)")
                    case .failure(let error):
                        print("X_HOME_ANCHOR_ACCEPTANCE error=\(error.localizedDescription)")
                    }
                }
            }
        }
        #endif
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
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
