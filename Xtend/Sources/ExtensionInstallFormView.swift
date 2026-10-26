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
    private let sourceNote = UILabel()
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
        urlField.placeholder = "Chrome拡張機能のURL"
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

        sourceNote.font = .preferredFont(forTextStyle: .footnote)
        sourceNote.adjustsFontForContentSizeCategory = true
        sourceNote.textColor = .secondaryLabel
        sourceNote.numberOfLines = 0
        sourceNote.accessibilityIdentifier = "xtend.install.source-note"
        setCustomSpacing(6, after: zipButton)
        addArrangedSubview(sourceNote)
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
        sourceNote.text = isGitHub
            ? "GitHubの最新ReleaseからZIPを取得します。非公開リポジトリは読み取り用トークンが必要です。"
            : "Chrome Web StoreのURLから追加できます。ZIPファイルも利用できます。"
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

/// 初回案内と設定画面で共有するおすすめ一覧。
@MainActor
final class RecommendedExtensionsView: UIStackView {
    var onInstallURL: ((String) -> Void)?
    private struct Recommendation {
        let title: String
        let detail: String
        let source: URL
        let sourceLabel: String
        let installURL: String?
        let fixedID: String?
        let note: String?

        var trackedSource: String? { fixedID ?? installURL }
    }

    private static let entries: [Recommendation] = [
        Recommendation(
            title: "にゃっとランドforX", detail: "Xでの交流や反応を見やすくする",
            source: ExtensionInstallStore.defaultStoreURL, sourceLabel: "Chrome Web Store",
            installURL: ExtensionInstallStore.defaultStoreURL.absoluteString,
            fixedID: ExtensionInstallStore.supportedExtensionID, note: nil
        ),
        Recommendation(
            title: "X Ad Hider", detail: "Xの広告ポストを非表示にする",
            source: URL(string: "https://github.com/kikutadev/x-ad-hider")!, sourceLabel: "GitHub",
            installURL: "https://github.com/kikutadev/x-ad-hider",
            fixedID: nil, note: nil
        ),
        Recommendation(
            title: "X Timeline Filter", detail: "指定したアカウントの投稿だけを表示する",
            source: URL(string: "https://github.com/kikutadev/x-timeline-filter")!, sourceLabel: "GitHub",
            installURL: "https://github.com/kikutadev/x-timeline-filter",
            fixedID: nil, note: nil
        ),
        Recommendation(
            title: "x-home-anchor", detail: "ホームの閲覧位置を維持する",
            source: URL(string: "https://github.com/akiweb8528/x-home-anchor/tree/main/release")!,
            sourceLabel: "配布ZIPを開く", installURL: nil,
            fixedID: ExtensionPackage.homeAnchorID,
            note: "配布ZIPを保存し「ZIPでインストール」から選択してください。公開Releaseはありません。"
        )
    ]

    private var buttons: [(recommendation: Recommendation, button: UIButton)] = []
    private var installedSources: Set<String> = []
    private var installedNames: Set<String> = []
    private var busy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 12
        let heading = UILabel()
        heading.text = "おすすめChrome拡張機能"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        addArrangedSubview(heading)
        for entry in Self.entries {
            addArrangedSubview(makeRecommendation(entry))
        }
        refreshActions()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setBusy(_ value: Bool) {
        busy = value
        refreshActions()
    }

    func updateInstalled(items: [InstalledExtensionInfo]) {
        let valid = items.filter { $0.issue == nil }
        installedSources = Set(valid.map(\.id))
        installedNames = Set(valid.map { $0.name.lowercased() })
        for item in valid {
            if let linked = GitHubReleaseLinks.get(item.id) {
                installedSources.insert(linked.repository)
            }
        }
        refreshActions()
    }

    private func refreshActions() {
        for (item, button) in buttons {
            let installed = item.trackedSource.map(installedSources.contains) == true ||
                installedNames.contains(item.title.lowercased())
            var configuration = button.configuration ?? .bordered()
            configuration.title = installed ? "追加済み" : "追加"
            button.configuration = configuration
            button.isEnabled = !busy && !installed
            button.accessibilityLabel = installed ? "\(item.title)は追加済み" : "\(item.title)を追加"
        }
    }

    private func makeRecommendation(_ item: Recommendation) -> UIView {
        let name = UILabel()
        name.text = item.title
        name.font = .preferredFont(forTextStyle: .body)
        name.numberOfLines = 0
        name.adjustsFontForContentSizeCategory = true

        let header = UIStackView(arrangedSubviews: [name])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        if let installURL = item.installURL {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.bordered()
            configuration.title = "追加"
            configuration.buttonSize = .medium
            button.configuration = configuration
            button.accessibilityIdentifier = "xtend.recommend.install.\(item.title)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onInstallURL?(installURL)
            }, for: .touchUpInside)
            button.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(button)
            buttons.append((item, button))
        }

        let description = UILabel()
        description.text = item.detail
        description.font = .preferredFont(forTextStyle: .footnote)
        description.textColor = .secondaryLabel
        description.numberOfLines = 0
        description.adjustsFontForContentSizeCategory = true

        let sourceButton = UIButton(type: .system)
        sourceButton.contentHorizontalAlignment = .leading
        sourceButton.setTitle("\(item.sourceLabel) ↗", for: .normal)
        sourceButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        sourceButton.accessibilityLabel = "\(item.title)の配布元を開く"
        sourceButton.addAction(UIAction { _ in UIApplication.shared.open(item.source) },
                               for: .touchUpInside)
        sourceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let links = UIStackView(arrangedSubviews: [sourceButton])
        links.axis = .horizontal
        links.alignment = .center

        let copyButton = UIButton(type: .system)
        copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copyButton.accessibilityLabel = "\(item.title)のリンクをコピー"
        copyButton.addAction(UIAction { _ in
            UIPasteboard.general.string = item.source.absoluteString
            UIAccessibility.post(notification: .announcement, argument: "リンクをコピーしました")
        }, for: .touchUpInside)
        copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        links.addArrangedSubview(copyButton)

        let column = UIStackView(arrangedSubviews: [header, description, links])
        column.axis = .vertical
        column.spacing = 2
        if let note = item.note {
            let noteLabel = UILabel()
            noteLabel.text = note
            noteLabel.font = .preferredFont(forTextStyle: .footnote)
            noteLabel.textColor = .secondaryLabel
            noteLabel.numberOfLines = 0
            noteLabel.adjustsFontForContentSizeCategory = true
            column.addArrangedSubview(noteLabel)
        }
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        column.layer.cornerRadius = 12
        column.backgroundColor = .secondarySystemGroupedBackground
        return column
    }
}
