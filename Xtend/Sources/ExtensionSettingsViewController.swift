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
        installedList.onCheckRelease = { [weak self] in self?.checkRelease($0) }
        stack.addArrangedSubview(installedList)

        let empty = UILabel()
        empty.text = "インストール済みの拡張機能はありません。"
        empty.textColor = .secondaryLabel
        empty.font = .preferredFont(forTextStyle: .body)
        empty.numberOfLines = 0
        empty.tag = 101
        stack.addArrangedSubview(empty)

        installForm.onInstallURL = { [weak self] value, token in self?.installFromURL(value, githubToken: token) }
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
        let developerSettings = makeDeveloperSettings()
        stack.addArrangedSubview(developerSettings)
        stack.setCustomSpacing(30, after: developerSettings)
        stack.addArrangedSubview(RecommendedExtensionsView())
    }

    private func makeDeveloperSettings() -> UIView {
        let heading = UILabel()
        heading.text = "開発者向け"
        heading.font = .preferredFont(forTextStyle: .headline)

        let label = UILabel()
        label.text = "タッチ操作を表示"
        label.font = .preferredFont(forTextStyle: .body)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let touchSwitch = UISwitch()
        touchSwitch.accessibilityIdentifier = "xtend.developer.showTouches"
        touchSwitch.isOn = DeveloperOptions.showsTouches
        touchSwitch.addAction(UIAction { action in
            guard let control = action.sender as? UISwitch else { return }
            DeveloperOptions.showsTouches = control.isOn
        }, for: .valueChanged)

        let toggleRow = UIStackView(arrangedSubviews: [label, touchSwitch])
        toggleRow.axis = .horizontal
        toggleRow.alignment = .center
        toggleRow.spacing = 12

        let note = UILabel()
        note.text = "タップ位置とスワイプの軌跡を画面に表示します。画面収録にも映ります。"
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0

        let section = UIStackView(arrangedSubviews: [heading, toggleRow, note])
        section.axis = .vertical
        section.spacing = 12
        return section
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

    private func installFromURL(_ value: String, githubToken: String?) {
        guard !busy else { return }
        view.endEditing(true)
        setBusy(true, message: "拡張機能を取得しています…")
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await ExtensionURLInstaller.install(value, githubToken: githubToken)
                }.value
                setBusy(false, message: nil)
                installForm.didFinishInstallation()
                refreshInstalled(animated: true)
                onChange()
            } catch {
                setBusy(false, message: nil)
                showError(error)
            }
        }
    }

    private func checkRelease(_ item: InstalledExtensionInfo) {
        guard !busy else { return }
        let linked = GitHubReleaseLinks.get(item.id)
        if let linked, let repo = GitHubReleaseRepository(input: linked.repository) {
            fetchRelease(for: item, repository: repo, token: nil)
        } else {
            promptForRepository(item)
        }
    }

    private func promptForRepository(_ item: InstalledExtensionInfo) {
        let alert = UIAlertController(title: "\(item.name)のGitHub取得元",
                                      message: "GitHubのクローンURLを貼り付けてください。", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://github.com/owner/repo.git"
            field.text = GitHubReleaseLinks.get(item.id)?.repository
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityLabel = "GitHubクローンURL"
        }
        alert.addTextField { field in
            field.placeholder = "Private用トークン（必要な場合）"
            field.isSecureTextEntry = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityLabel = "GitHub読み取り用トークン"
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "更新を確認", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let input = alert.textFields?[0].text ?? ""
            let token = alert.textFields?[1].text
            guard let repository = GitHubReleaseRepository(input: input) else {
                self.showError(GitHubReleaseError.invalidURL)
                return
            }
            self.fetchRelease(for: item, repository: repository, token: token)
        })
        present(alert, animated: true)
    }

    private func fetchRelease(for item: InstalledExtensionInfo, repository: GitHubReleaseRepository,
                              token: String?) {
        guard !busy else { return }
        setBusy(true, message: "GitHubの最新Releaseを確認しています…")
        Task { [weak self] in
            do {
                let previous = GitHubReleaseLinks.get(item.id)
                let storedTag = previous?.repository == repository.webURL.absoluteString
                    ? previous?.installedTag : nil
                let result = try await GitHubReleaseInstaller.check(
                    repository: repository, installedVersion: item.version,
                    installedTag: storedTag, tokenOverride: token
                )
                if let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !trimmed.isEmpty {
                    try GitHubReleaseCredentials.save(trimmed)
                }
                GitHubReleaseLinks.save(id: item.id, repository: repository, tag: storedTag)
                guard let self else { return }
                setBusy(false, message: nil)
                let message = "インストール済み：\(item.version)\n最新Release：\(result.release.tagName)"
                let alert = UIAlertController(title: result.needsUpdate ? "更新があります" : "最新です",
                                              message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
                if result.needsUpdate {
                    alert.addAction(UIAlertAction(title: "最新版を取り込む", style: .default) { [weak self] _ in
                        self?.applyGitHubUpdate(item, repository: repository)
                    })
                }
                alert.addAction(UIAlertAction(title: "取得元を変更", style: .default) { [weak self] _ in
                    self?.promptForRepository(item)
                })
                present(alert, animated: true)
            } catch {
                self?.setBusy(false, message: nil)
                let alert = UIAlertController(title: "確認できませんでした",
                                              message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
                alert.addAction(UIAlertAction(title: "取得元を変更", style: .default) { [weak self] _ in
                    self?.promptForRepository(item)
                })
                self?.present(alert, animated: true)
            }
        }
    }

    private func applyGitHubUpdate(_ item: InstalledExtensionInfo, repository: GitHubReleaseRepository) {
        guard !busy else { return }
        setBusy(true, message: "最新Releaseを取得しています…")
        Task { [weak self] in
            do {
                _ = try await GitHubReleaseInstaller.installLatest(
                    repository: repository, newToken: nil, existingID: item.id
                )
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
                        do {
                            _ = try ExtensionInstallStore().installFromZIP(url)
                        } catch ExtensionInstallError.missingRequiredCapability {
                            _ = try CommunityExtensionStore().installFromZIP(url)
                        }
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
        guard item.hasSettings else { return }
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

/// Installed extension popup/options page, isolated from X and other extensions.
@MainActor
final class ExtensionPopupViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let configuration: WKWebViewConfiguration
    private let host: ExtensionHost
    private var browser: WKWebView?
    private let extensionID: String
    private let page: ExtensionPackage.SettingsPage

    init(extensionID: String) throws {
        let runtime = ExtensionRuntime()
        guard let package = runtime.packages.first(where: { $0.id == extensionID }),
              let page = package.settingsPage else {
            throw RuntimeError.missingResource(extensionID)
        }
        let (configuration, host) = try runtime.makeSettingsConfiguration(for: extensionID)
        self.configuration = configuration
        self.host = host
        self.extensionID = extensionID
        self.page = page
        super.init(nibName: nil, bundle: nil)
        title = "\(package.manifest.name ?? extensionID)の設定"
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
        let width = browser.widthAnchor.constraint(equalToConstant: page.prefersWideLayout ? 420 : 350)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            browser.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            browser.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            width,
            browser.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24)
        ])
        let url = URL(string: "\(ExtensionResourceSchemeHandler.scheme)://\(extensionID)/\(page.path)")!
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
           url.host == extensionID {
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
           url.host == extensionID {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }
}