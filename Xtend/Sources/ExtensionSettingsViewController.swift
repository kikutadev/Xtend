import UIKit
import UniformTypeIdentifiers
import WebKit

/// Settings-only management. The first-run screen is a welcome/recommendations screen.
@MainActor
final class ExtensionSettingsViewController: UIViewController, UIDocumentPickerDelegate {
    private let onReload: () -> Void
    private let onChange: () -> Void
    private let onFinish: () -> Void
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let installedList = InstalledExtensionsListView()
    private let installForm = ExtensionInstallFormView()
    private let reloadButton = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)
    private let status = UILabel()
    private var busy = false

    init(onReload: @escaping () -> Void, onChange: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.onReload = onReload
        self.onChange = onChange
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        title = "Xtendの設定"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let onFinish = self.onFinish
                self.dismiss(animated: true, completion: onFinish)
            }
        )
        setup()
        refreshInstalled(animated: false)
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        let logo = UIImageView(image: UIImage(named: "XtendBrand"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 60),
            logo.heightAnchor.constraint(equalToConstant: 60)
        ])
        let appName = UILabel()
        appName.text = "Xtend"
        appName.font = .systemFont(ofSize: 34, weight: .bold)
        let branding = UIStackView(arrangedSubviews: [logo, appName])
        branding.axis = .horizontal
        branding.alignment = .center
        branding.spacing = 14
        stack.addArrangedSubview(branding)
        stack.setCustomSpacing(28, after: branding)

        installedList.onRemove = { [weak self] in self?.confirmRemove($0) }
        installedList.onSettings = { [weak self] in self?.openExtensionSettings($0) }
        stack.addArrangedSubview(installedList)

        let empty = UILabel()
        empty.text = "インストール済みの拡張機能はありません。"
        empty.textColor = .secondaryLabel
        empty.font = .preferredFont(forTextStyle: .body)
        empty.numberOfLines = 0
        empty.tag = 101
        stack.addArrangedSubview(empty)

        installForm.onInstallURL = { [weak self] value in self?.installFromStore(value) }
        installForm.onSelectZIP = { [weak self] in self?.selectZIP() }
        stack.setCustomSpacing(30, after: empty)
        stack.addArrangedSubview(installForm)

        activity.hidesWhenStopped = true
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.isHidden = true
        let progress = UIStackView(arrangedSubviews: [activity, status])
        progress.axis = .horizontal
        progress.alignment = .center
        progress.spacing = 8
        stack.addArrangedSubview(progress)

        var reloadConfig = UIButton.Configuration.borderedProminent()
        reloadConfig.title = "Xのページを再読み込み"
        reloadConfig.image = UIImage(systemName: "arrow.clockwise")
        reloadConfig.imagePadding = 8
        reloadButton.configuration = reloadConfig
        reloadButton.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)
        reloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        stack.setCustomSpacing(30, after: progress)
        stack.addArrangedSubview(reloadButton)

        let hint = UILabel()
        hint.text = "拡張機能の追加・更新・削除は、設定画面を閉じると自動反映されます。"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.numberOfLines = 0
        hint.textColor = .secondaryLabel
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(30, after: hint)
        stack.addArrangedSubview(RecommendedExtensionsView())
    }

    private func refreshInstalled(animated: Bool) {
        let items = InstalledExtensionCatalog.all()
        installedList.update(items: items, animated: animated)
        stack.arrangedSubviews.first(where: { $0.tag == 101 })?.isHidden = !items.isEmpty
    }

    private func setBusy(_ busy: Bool, message: String?) {
        self.busy = busy
        isModalInPresentation = busy
        navigationItem.rightBarButtonItem?.isEnabled = !busy
        installForm.setBusy(busy)
        reloadButton.isEnabled = !busy
        status.text = message
        status.isHidden = message == nil
        busy ? activity.startAnimating() : activity.stopAnimating()
    }

    private func installFromStore(_ value: String) {
        guard !busy else { return }
        view.endEditing(true)
        guard let url = URL(string: value) else {
            showError(ExtensionInstallError.invalidChromeWebStoreURL)
            return
        }
        setBusy(true, message: "Chrome Web Storeから取得しています…")
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ExtensionInstallStore().installFromChromeWebStore(url)
                setBusy(false, message: nil)
                refreshInstalled(animated: true)
                onChange()
            } catch {
                setBusy(false, message: nil)
                showError(error)
            }
        }
    }

    private func selectZIP() {
        guard !busy else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, !busy else { return }
        setBusy(true, message: "ZIPファイルを検証しています…")
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    do {
                        _ = try XHomeAnchorInstallStore().installFromZIP(url)
                    } catch XHomeAnchorInstallError.unsupportedPackage {
                        _ = try ExtensionInstallStore().installFromZIP(url)
                    }
                }.value
                guard let self else { return }
                setBusy(false, message: nil)
                refreshInstalled(animated: true)
                onChange()
            } catch {
                self?.setBusy(false, message: nil)
                self?.showError(error)
            }
        }
    }

    private func confirmRemove(_ item: InstalledExtensionInfo) {
        let alert = UIAlertController(
            title: "\(item.name)を削除しますか？",
            message: "拡張機能のファイルと端末内の設定を削除します。Xのログイン状態は保持します。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            do {
                try InstalledExtensionCatalog.remove(id: item.id)
                self?.refreshInstalled(animated: true)
                self?.onChange()
            } catch {
                self?.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func openExtensionSettings(_ item: InstalledExtensionInfo) {
        guard item.id == ExtensionInstallStore.supportedExtensionID else { return }
        do {
            let popup = try ExtensionPopupViewController(extensionID: item.id)
            navigationController?.pushViewController(popup, animated: true)
        } catch { showError(error) }
    }

    @objc private func reloadPage() {
        guard !busy else { return }
        onReload()
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "拡張機能を操作できませんでした",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// Fixed-width Chrome popup centered in the screen instead of left-aligned in a full-width WebView.
@MainActor
final class ExtensionPopupViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let configuration: WKWebViewConfiguration
    private let host: ExtensionHost
    private var browser: WKWebView?

    init(extensionID: String) throws {
        guard extensionID == ExtensionInstallStore.supportedExtensionID else {
            throw RuntimeError.missingResource(extensionID)
        }
        let runtime = ExtensionRuntime()
        let (configuration, host) = try runtime.makeSettingsConfiguration()
        self.configuration = configuration
        self.host = host
        super.init(nibName: nil, bundle: nil)
        title = "にゃっとランドの設定"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let browser = WKWebView(frame: .zero, configuration: configuration)
        self.browser = browser
        host.attach(to: browser)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.isOpaque = false
        browser.backgroundColor = .systemBackground
        browser.scrollView.contentInsetAdjustmentBehavior = .never
        browser.layer.cornerRadius = 12
        browser.layer.masksToBounds = true
        browser.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser)
        let width = browser.widthAnchor.constraint(equalToConstant: 350)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            browser.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            browser.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            width,
            browser.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24)
        ])
        let url = URL(string: "\(ExtensionResourceSchemeHandler.scheme)://\(ExtensionInstallStore.supportedExtensionID)/popup.html")!
        browser.load(URLRequest(url: url))
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
        if url.scheme == ExtensionResourceSchemeHandler.scheme,
           url.host == ExtensionInstallStore.supportedExtensionID {
            decisionHandler(.allow)
        } else {
            if url.scheme == "https", navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == ExtensionResourceSchemeHandler.scheme,
           url.host == ExtensionInstallStore.supportedExtensionID {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }
}