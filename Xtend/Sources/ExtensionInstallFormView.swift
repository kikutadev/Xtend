import UIKit

/// 初回案内と設定で使う同じ拡張機能インストール操作。
@MainActor
final class ExtensionInstallFormView: UIStackView, UITextFieldDelegate {
    var onInstallURL: ((String, String?) -> Void)?
    var onSelectZIP: (() -> Void)?

    private let urlField = UITextField()
    private let installButton = UIButton(type: .system)
    private let zipButton = UIButton(type: .system)
    private let githubTokenField = UITextField()
    private let clearTokenButton = UIButton(type: .system)
    private var busy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 16

        let heading = UILabel()
        heading.text = "Chrome拡張機能を追加"
        heading.font = .preferredFont(forTextStyle: .title3)
        heading.adjustsFontForContentSizeCategory = true
        addArrangedSubview(heading)

        urlField.borderStyle = .roundedRect
        urlField.placeholder = "Chrome Web Store / GitHubのURL"
        urlField.keyboardType = .URL
        urlField.textContentType = .URL
        urlField.autocorrectionType = .no
        urlField.autocapitalizationType = .none
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.accessibilityLabel = "拡張機能のURL"
        urlField.delegate = self
        urlField.addTarget(self, action: #selector(updateInstallButton), for: .editingChanged)
        addArrangedSubview(urlField)

        githubTokenField.borderStyle = .roundedRect
        githubTokenField.placeholder = GitHubReleaseCredentials.load() == nil
            ? "Private GitHub用トークン（任意）" : "トークン保存済み（変更する場合は入力）"
        githubTokenField.isSecureTextEntry = true
        githubTokenField.autocorrectionType = .no
        githubTokenField.autocapitalizationType = .none
        githubTokenField.accessibilityLabel = "GitHubの読み取り用トークン"
        githubTokenField.isHidden = true
        addArrangedSubview(githubTokenField)

        clearTokenButton.setTitle("保存トークンを削除", for: .normal)
        clearTokenButton.contentHorizontalAlignment = .leading
        clearTokenButton.addAction(UIAction { [weak self] _ in
            GitHubReleaseCredentials.remove()
            self?.githubTokenField.text = ""
            self?.githubTokenField.placeholder = "Private GitHub用トークン（任意）"
            self?.updateInstallButton()
        }, for: .touchUpInside)
        clearTokenButton.isHidden = true
        addArrangedSubview(clearTokenButton)

        var installConfig = UIButton.Configuration.filled()
        installConfig.title = "インストール"
        installConfig.image = UIImage(systemName: "arrow.down.circle")
        installConfig.imagePadding = 9
        installButton.configuration = installConfig
        installButton.addTarget(self, action: #selector(submitURL), for: .touchUpInside)
        installButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        addArrangedSubview(installButton)

        var zipConfig = UIButton.Configuration.bordered()
        zipConfig.title = "ZIPでインストール"
        zipConfig.image = UIImage(systemName: "folder")
        zipConfig.imagePadding = 9
        zipButton.configuration = zipConfig
        zipButton.addTarget(self, action: #selector(selectZIP), for: .touchUpInside)
        zipButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        addArrangedSubview(zipButton)

        let note = UILabel()
        note.text = "GitHubのリポジトリURLから最新ReleaseのZIPを取得します。Privateは読み取り用トークンが必要です。"
        note.font = .preferredFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        setCustomSpacing(6, after: zipButton)
        addArrangedSubview(note)
        updateInstallButton()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func didFinishInstallation() {
        githubTokenField.text = nil
        githubTokenField.placeholder = GitHubReleaseCredentials.load() == nil
            ? "Private GitHub用トークン（任意）" : "トークン保存済み（変更する場合は入力）"
        updateInstallButton()
    }

    func setBusy(_ value: Bool) {
        busy = value
        urlField.isEnabled = !value
        zipButton.isEnabled = !value
        githubTokenField.isEnabled = !value
        clearTokenButton.isEnabled = !value
        updateInstallButton()
    }

    @objc private func updateInstallButton() {
        let value = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isGitHub = GitHubReleaseRepository(input: value) != nil
        githubTokenField.isHidden = !isGitHub
        clearTokenButton.isHidden = !isGitHub || GitHubReleaseCredentials.load() == nil
        installButton.isEnabled = !busy && !value.isEmpty
    }

    @objc private func submitURL() {
        guard !busy, let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        urlField.resignFirstResponder()
        onInstallURL?(text, githubTokenField.text)
    }

    @objc private func selectZIP() {
        guard !busy else { return }
        onSelectZIP?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitURL()
        return true
    }
}

/// 初回案内と設定画面で共通利用する、X向け拡張機能の追加導線。
/// 配布用Releaseがないリポジトリは直接インストール対象にしない。
@MainActor
final class RecommendedExtensionsView: UIStackView {
    var onInstallURL: ((String) -> Void)?
    private var busy = false
    private var installButtons: [(source: String, name: String, button: UIButton)] = []
    private var installedSources: Set<String> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 12

        let heading = UILabel()
        heading.text = "おすすめChrome拡張機能"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        addArrangedSubview(heading)

        addArrangedSubview(makeRecommendation(
            title: "にゃっとランドforX",
            detail: "Xでの交流や反応を見やすくする",
            sourceName: "Chrome Web Store",
            sourceURL: ExtensionInstallStore.defaultStoreURL,
            installURL: ExtensionInstallStore.defaultStoreURL.absoluteString,
            installedSource: ExtensionInstallStore.supportedExtensionID
        ))
        addArrangedSubview(makeRecommendation(
            title: "X Ad Hider",
            detail: "Xの広告ポストを非表示にする",
            sourceName: "GitHub",
            sourceURL: URL(string: "https://github.com/kikutadev/x-ad-hider")!,
            installURL: "https://github.com/kikutadev/x-ad-hider"
        ))
        addArrangedSubview(makeRecommendation(
            title: "X Timeline Filter",
            detail: "指定したアカウントの投稿だけを表示する",
            sourceName: "GitHub",
            sourceURL: URL(string: "https://github.com/kikutadev/x-timeline-filter")!,
            installURL: "https://github.com/kikutadev/x-timeline-filter"
        ))
        addArrangedSubview(makeRecommendation(
            title: "x-home-anchor",
            detail: "ホームの閲覧位置を維持する",
            sourceName: "配布ZIPを開く",
            sourceURL: URL(string: "https://github.com/akiweb8528/x-home-anchor/tree/main/release")!,
            note: "配布用ZIPを保存して「ZIPでインストール」から選択してください。このリポジトリには公開Releaseがありません。"
        ))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setBusy(_ value: Bool) {
        busy = value
        refreshActions()
    }

    func updateInstalled(items: [InstalledExtensionInfo]) {
        installedSources = Set(items.map(\.id))
        for item in items {
            if item.name.caseInsensitiveCompare("X Ad Hider") == .orderedSame {
                installedSources.insert("https://github.com/kikutadev/x-ad-hider")
            }
            if item.name.caseInsensitiveCompare("X Timeline Filter") == .orderedSame {
                installedSources.insert("https://github.com/kikutadev/x-timeline-filter")
            }
            if let linked = GitHubReleaseLinks.get(item.id) {
                installedSources.insert(linked.repository)
            }
        }
        refreshActions()
    }

    private func refreshActions() {
        for (source, name, button) in installButtons {
            let installed = installedSources.contains(source)
            var configuration = button.configuration ?? .bordered()
            configuration.title = installed ? "追加済み" : "追加"
            button.configuration = configuration
            button.isEnabled = !busy && !installed
            button.accessibilityLabel = installed ? "\(name)は追加済み" : "\(name)を追加"
        }
    }

    private func makeRecommendation(
        title: String, detail: String, sourceName: String, sourceURL: URL,
        installURL: String? = nil, installedSource: String? = nil, note: String? = nil
    ) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .preferredFont(forTextStyle: .body)
        name.numberOfLines = 0
        name.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [name])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        if let installURL {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.bordered()
            config.title = "追加"
            config.buttonSize = .medium
            button.configuration = config
            button.accessibilityIdentifier = "xtend.recommend.install.\(title)"
            button.addAction(UIAction { [weak self] _ in
                self?.onInstallURL?(installURL)
            }, for: .touchUpInside)
            button.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(button)
            installButtons.append((installedSource ?? installURL, title, button))
        }

        let description = UILabel()
        description.text = detail
        description.font = .preferredFont(forTextStyle: .footnote)
        description.textColor = .secondaryLabel
        description.adjustsFontForContentSizeCategory = true
        description.numberOfLines = 0

        let link = UIButton(type: .system)
        link.contentHorizontalAlignment = .leading
        link.setTitle("\(sourceName) ↗", for: .normal)
        link.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        link.accessibilityLabel = "\(title)の配布元を開く"
        link.addAction(UIAction { _ in UIApplication.shared.open(sourceURL) }, for: .touchUpInside)
        link.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let column = UIStackView(arrangedSubviews: [header, description, link])
        column.axis = .vertical
        column.spacing = 2
        if let note {
            let help = UILabel()
            help.text = note
            help.font = .preferredFont(forTextStyle: .footnote)
            help.textColor = .secondaryLabel
            help.numberOfLines = 0
            column.addArrangedSubview(help)
        }
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        column.layer.cornerRadius = 12
        column.backgroundColor = .secondarySystemGroupedBackground
        return column
    }
}
