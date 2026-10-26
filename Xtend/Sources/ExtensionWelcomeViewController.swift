import UIKit
import UniformTypeIdentifiers

@MainActor
final class ExtensionWelcomeViewController: UIViewController, UIDocumentPickerDelegate {
    private let onContinue: () -> Void

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let installForm = ExtensionInstallFormView()
    private let recommendations = RecommendedExtensionsView()
    private let continueButton = UIButton(type: .system)
    private let installedList = InstalledExtensionsListView()
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var busy = false

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        setup()
        refreshInstalled(animated: false)
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
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
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -22),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -44)
        ])

        let symbol = UIImageView(image: UIImage(named: "XtendBrand") ?? UIImage(systemName: "puzzlepiece.extension.fill"))
        symbol.contentMode = .scaleAspectFit
        symbol.tintColor = .label
        symbol.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 60),
            symbol.heightAnchor.constraint(equalToConstant: 60)
        ])
        let name = label("Xtend", style: .largeTitle)
        name.font = .systemFont(ofSize: 34, weight: .bold)
        let heading = UIStackView(arrangedSubviews: [symbol, name])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 14
        stack.addArrangedSubview(heading)

        installForm.onInstallURL = { [weak self] value, token in self?.installFromURL(value, githubToken: token) }
        installForm.onSelectZIP = { [weak self] in self?.selectZIP() }
        recommendations.onInstallURL = { [weak self] value in self?.installFromURL(value, githubToken: nil) }
        recommendations.onRequireGitHubToken = { [weak self] value in self?.prepareRecommendedGitHubURL(value) }
        stack.setCustomSpacing(32, after: heading)
        stack.addArrangedSubview(installForm)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .secondaryLabel
        statusLabel.isHidden = true
        activity.hidesWhenStopped = true
        let feedback = UIStackView(arrangedSubviews: [activity, statusLabel])
        feedback.axis = .horizontal
        feedback.alignment = .center
        feedback.spacing = 8
        stack.addArrangedSubview(feedback)

        installedList.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(installedList)

        var continueConfig = UIButton.Configuration.borderedProminent()
        continueConfig.title = "インストールせずにXを見る"
        continueConfig.image = UIImage(systemName: "arrow.right")
        continueConfig.imagePlacement = .trailing
        continueButton.configuration = continueConfig
        continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        continueButton.addTarget(self, action: #selector(openX), for: .touchUpInside)
        stack.setCustomSpacing(28, after: installedList)
        stack.addArrangedSubview(continueButton)

        let loginNote = label("※ Googleなどの外部サービスを利用したXへのログインは、WebViewの制限で失敗する場合があります。", style: .footnote)
        loginNote.textColor = .secondaryLabel
        stack.setCustomSpacing(8, after: continueButton)
        stack.addArrangedSubview(loginNote)

        stack.setCustomSpacing(36, after: loginNote)
        stack.addArrangedSubview(recommendations)
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func refreshInstalled(animated: Bool) {
        let items = InstalledExtensionCatalog.all()
        installedList.update(items: items, animated: animated)
        recommendations.updateInstalled(items: items)
        var config = continueButton.configuration ?? .borderedProminent()
        config.title = items.isEmpty ? "インストールせずにXを見る" : "Xを見る"
        continueButton.configuration = config
        if animated, !items.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scrollView.layoutIfNeeded()
            scrollView.scrollRectToVisible(installedList.convert(installedList.bounds, to: scrollView),
                                           animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func setBusy(_ value: Bool, message: String?) {
        busy = value
        installForm.setBusy(value)
        recommendations.setBusy(value)
        continueButton.isEnabled = !value
        statusLabel.text = message
        statusLabel.isHidden = message == nil
        value ? activity.startAnimating() : activity.stopAnimating()
    }

    private func prepareRecommendedGitHubURL(_ value: String) {
        guard !busy else { return }
        installForm.prepareGitHubURL(value)
        scrollView.scrollRectToVisible(installForm.convert(installForm.bounds, to: scrollView),
                                       animated: !UIAccessibility.isReduceMotionEnabled)
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
            } catch {
                setBusy(false, message: nil)
                showError(error)
            }
        }
    }

    private func selectZIP() {
        guard !busy else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
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
            } catch {
                self?.setBusy(false, message: nil)
                self?.showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "インストールできませんでした",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func openX() {
        guard !busy else { return }
        onContinue()
    }
}