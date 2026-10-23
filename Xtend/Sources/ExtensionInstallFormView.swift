import UIKit

/// 初回案内と設定で使う同じ拡張機能インストール操作。
@MainActor
final class ExtensionInstallFormView: UIStackView, UITextFieldDelegate {
    var onInstallURL: ((String) -> Void)?
    var onSelectZIP: (() -> Void)?

    private let urlField = UITextField()
    private let installButton = UIButton(type: .system)
    private let zipButton = UIButton(type: .system)
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
        urlField.placeholder = "Chrome拡張機能のURLを貼り付け"
        urlField.keyboardType = .URL
        urlField.textContentType = .URL
        urlField.autocorrectionType = .no
        urlField.autocapitalizationType = .none
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .go
        urlField.accessibilityLabel = "Chrome拡張機能のURL"
        urlField.delegate = self
        urlField.addTarget(self, action: #selector(updateInstallButton), for: .editingChanged)
        addArrangedSubview(urlField)

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
        note.text = "ファイル選択のメニューが開きます。\nZIPをiPhoneにダウンロード後、選択してください。\n信頼できる配布元のZIPのみインストールしてください。"
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

    func setBusy(_ value: Bool) {
        busy = value
        urlField.isEnabled = !value
        zipButton.isEnabled = !value
        updateInstallButton()
    }

    @objc private func updateInstallButton() {
        let hasInput = !(urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        installButton.isEnabled = !busy && hasInput
    }

    @objc private func submitURL() {
        guard !busy, let text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        urlField.resignFirstResponder()
        onInstallURL?(text)
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

/// おすすめリンクは開くかコピーするだけ。入力欄への自動入力は行わない。
@MainActor
final class RecommendedExtensionsView: UIStackView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 14

        let heading = UILabel()
        heading.text = "おすすめChrome拡張機能"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.adjustsFontForContentSizeCategory = true
        addArrangedSubview(heading)

        addArrangedSubview(makeRecommendation(
            title: "にゃっとランドforX",
            destination: "Chrome Web Store",
            url: ExtensionInstallStore.defaultStoreURL
        ))
        addArrangedSubview(makeRecommendation(
            title: "X ホームの閲覧位置",
            destination: "GitHub",
            url: URL(string: "https://github.com/akiweb8528/x-home-anchor")!,
            note: "GitHubのReleasesから配布用ZIPをダウンロードし、「ZIPでインストール」から選択してください。",
            copyLink: false
        ))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private func makeRecommendation(
        title: String, destination: String, url: URL,
        note: String? = nil, copyLink: Bool = true
    ) -> UIView {
        let name = UILabel()
        name.text = title
        name.font = .preferredFont(forTextStyle: .headline)
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 0

        let linkButton = UIButton(type: .system)
        linkButton.contentHorizontalAlignment = .leading
        linkButton.setTitle("\(destination)  ↗", for: .normal)
        linkButton.addAction(UIAction { _ in UIApplication.shared.open(url) }, for: .touchUpInside)

        let links = UIStackView(arrangedSubviews: [linkButton, UIView()])
        links.axis = .horizontal
        links.alignment = .center
        if copyLink {
            let copyButton = UIButton(type: .system)
            copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
            copyButton.accessibilityLabel = "\(title)のリンクをコピー"
            copyButton.addAction(UIAction { _ in
                UIPasteboard.general.string = url.absoluteString
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: "リンクをコピーしました")
            }, for: .touchUpInside)
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            links.addArrangedSubview(copyButton)
        }

        let column = UIStackView(arrangedSubviews: [name, links])
        column.axis = .vertical
        column.spacing = 4
        if let note {
            let help = UILabel()
            help.text = note
            help.font = .preferredFont(forTextStyle: .footnote)
            help.textColor = .secondaryLabel
            help.numberOfLines = 0
            help.adjustsFontForContentSizeCategory = true
            column.addArrangedSubview(help)
        }
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        column.layer.cornerRadius = 12
        column.backgroundColor = .secondarySystemGroupedBackground
        return column
    }
}