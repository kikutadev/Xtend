import UIKit

struct InstalledExtensionInfo {
    let id: String
    let name: String
    let version: String
    let icon: UIImage?
    let issue: String?
    var hasSettings = false
    var chromeWebStoreURL: URL?
}

@MainActor
enum InstalledExtensionCatalog {
    static func all() -> [InstalledExtensionInfo] {
        var result: [InstalledExtensionInfo] = []
        let store = ExtensionInstallStore()
        if let root = store.existingRoot {
            if let manifest = try? ExtensionInstallStore.readAndValidateManifest(at: root) {
                result.append(info(id: ExtensionInstallStore.supportedExtensionID, root: root, manifest: manifest))
            } else {
                result.append(InstalledExtensionInfo(
                    id: ExtensionInstallStore.supportedExtensionID,
                    name: "にゃっとランドforX", version: "不明", icon: nil, issue: "拡張機能のファイルを読み込めません"
                ))
            }
        } else if let issue = store.recoveryIssue {
            result.append(InstalledExtensionInfo(
                id: ExtensionInstallStore.supportedExtensionID, name: "にゃっとランドforX",
                version: "不明", icon: nil, issue: "復旧に失敗: \(issue)"
            ))
        }
        let anchorStore = XHomeAnchorInstallStore()
        if let root = anchorStore.existingRoot {
            if (try? XHomeAnchorInstallStore.validateManifest(at: root)) != nil,
               let package = try? ExtensionPackage.installed(id: ExtensionPackage.homeAnchorID, root: root) {
                result.append(info(id: package.id, root: root, manifest: package.manifest))
            } else {
                result.append(InstalledExtensionInfo(
                    id: ExtensionPackage.homeAnchorID,
                    name: "X ホームの閲覧位置", version: "不明", icon: nil, issue: "拡張機能のファイルを読み込めません"
                ))
            }
        } else if let issue = anchorStore.recoveryIssue {
            result.append(InstalledExtensionInfo(
                id: ExtensionPackage.homeAnchorID, name: "X ホームの閲覧位置",
                version: "不明", icon: nil, issue: "復旧に失敗: \(issue)"
            ))
        }
        for (id, root) in CommunityExtensionStore().installedRoots().sorted(by: { $0.key < $1.key }) {
            if (try? CommunityExtensionStore.validateManifest(at: root)) != nil,
               let package = try? ExtensionPackage.installed(id: id, root: root) {
                result.append(info(id: id, root: root, manifest: package.manifest))
            } else {
                result.append(InstalledExtensionInfo(
                    id: id, name: id, version: "不明", icon: nil,
                    issue: "拡張機能のファイルを読み込めません"
                ))
            }
        }
        return result
    }

    static func remove(id: String) throws {
        switch id {
        case ExtensionInstallStore.supportedExtensionID:
            try ExtensionInstallStore().uninstall()
        case ExtensionPackage.homeAnchorID:
            try XHomeAnchorInstallStore().uninstall()
        default:
            try CommunityExtensionStore().uninstall(id: id)
        }
        GitHubReleaseLinks.remove(id)
        // Clear SQLite values and migration leftovers, not only UserDefaults.
        try ExtensionStorage(extensionID: id).eraseAll()
    }

    private static func info(id: String, root: URL, manifest: InstalledExtensionManifest) -> InstalledExtensionInfo {
        let rawName = manifest.name ?? id
        let name = localized(rawName, locale: manifest.defaultLocale, root: root)
        let icons = (manifest.icons ?? [:]).sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }
        var icon: UIImage?
        for (_, relative) in icons {
            guard let file = safeFile(relative, root: root),
                  let image = UIImage(contentsOfFile: file.path) else { continue }
            icon = image
            break
        }
        var entry = InstalledExtensionInfo(id: id, name: name, version: manifest.version, icon: icon, issue: nil)
        entry.hasSettings = ExtensionPackage(id: id, root: root.standardizedFileURL, manifest: manifest).settingsPage != nil
        entry.chromeWebStoreURL = chromeWebStoreURL(for: id, root: root)
        return entry
    }

    static func chromeWebStoreURL(for id: String, root: URL) -> URL? {
        // Prefer the verified source recorded at install time over an unrelated GitHub repository.
        let metadataURL = root.appendingPathComponent(".xtend-install.json")
        if let data = try? Data(contentsOf: metadataURL),
           let metadata = try? JSONDecoder().decode(ExtensionInstallMetadata.self, from: data),
           metadata.id == id,
           case .chromeWebStore(let url) = metadata.source,
           (try? ExtensionInstallStore.extensionID(from: url)) == id {
            return url
        }
        // Existing Nyatto installs may predate install metadata.
        return id == ExtensionInstallStore.supportedExtensionID
            ? ExtensionInstallStore.defaultStoreURL : nil
    }

    private static func localized(_ name: String, locale: String?, root: URL) -> String {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2))
        let language = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init)
        let candidates = [language, locale, "ja", "en"].compactMap { $0 }
        for candidate in candidates {
            let messages = root.appendingPathComponent("_locales/\(candidate)/messages.json")
            guard let data = try? Data(contentsOf: messages),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
                  let value = dictionary[key]?["message"] as? String else { continue }
            return value
        }
        return name
    }

    private static func safeFile(_ path: String, root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\") else { return nil }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return file
    }
}

/// The same installed-extension rows are shown on welcome and in settings.
@MainActor
final class InstalledExtensionsListView: UIView {
    var onRemove: ((InstalledExtensionInfo) -> Void)?
    var onSettings: ((InstalledExtensionInfo) -> Void)?
    var onCheckRelease: ((InstalledExtensionInfo) -> Void)?
    private let content = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        content.axis = .vertical
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [InstalledExtensionInfo], animated: Bool = false) {
        for old in content.arrangedSubviews {
            content.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        guard !items.isEmpty else {
            isHidden = true
            return
        }

        let heading = UILabel()
        heading.text = "✓  インストール済みのChrome拡張機能"
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.numberOfLines = 0
        content.addArrangedSubview(heading)

        for item in items {
            let icon = UIImageView(image: item.icon ?? UIImage(systemName: "puzzlepiece.extension"))
            icon.tintColor = .secondaryLabel
            icon.contentMode = .scaleAspectFit
            icon.layer.cornerRadius = 10
            icon.clipsToBounds = true
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 46),
                icon.heightAnchor.constraint(equalToConstant: 46)
            ])
            let name = UILabel()
            name.text = item.name
            name.font = .preferredFont(forTextStyle: .body)
            name.numberOfLines = 2
            let detail = UILabel()
            detail.text = item.issue ?? "バージョン \(item.version)"
            detail.font = .preferredFont(forTextStyle: .caption1)
            detail.textColor = item.issue == nil ? .secondaryLabel : .systemOrange

            let labels = UIStackView(arrangedSubviews: [name, detail])
            labels.axis = .vertical
            labels.spacing = 3
            labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [icon, labels])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12

            if let onSettings {
                if item.hasSettings {
                    let button = UIButton(type: .system)
                    button.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
                    button.accessibilityLabel = "\(item.name)の設定"
                    button.isEnabled = item.issue == nil
                    button.addAction(UIAction { _ in onSettings(item) }, for: .touchUpInside)
                    button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
                    row.addArrangedSubview(button)
                } else {
                    let reservedSpace = UIView()
                    reservedSpace.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    row.addArrangedSubview(reservedSpace)
                }
            }
            if let onRemove {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "trash"), for: .normal)
                button.tintColor = .systemRed
                button.accessibilityLabel = "\(item.name)を削除"
                button.addAction(UIAction { _ in onRemove(item) }, for: .touchUpInside)
                button.widthAnchor.constraint(equalToConstant: 44).isActive = true
                button.heightAnchor.constraint(equalToConstant: 44).isActive = true
                row.addArrangedSubview(button)
            }
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            row.backgroundColor = .secondarySystemGroupedBackground
            row.layer.cornerRadius = 14
            if let onCheckRelease {
                let checkButton = UIButton(type: .system)
                checkButton.setTitle("更新を確認", for: .normal)
                checkButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
                checkButton.tintColor = .tintColor
                checkButton.contentHorizontalAlignment = .leading
                checkButton.accessibilityIdentifier = "xtend.release.check.\(item.id)"
                checkButton.accessibilityLabel = "\(item.name)の更新を確認"
                checkButton.isEnabled = item.issue == nil
                checkButton.addAction(UIAction { _ in onCheckRelease(item) }, for: .touchUpInside)
                checkButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                let column = UIStackView(arrangedSubviews: [row, checkButton])
                column.axis = .vertical
                column.spacing = 0
                content.addArrangedSubview(column)
            } else {
                content.addArrangedSubview(row)
            }
        }

        isHidden = false
        if animated && !UIAccessibility.isReduceMotionEnabled {
            alpha = 0
            transform = CGAffineTransform(translationX: 0, y: 14)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.78,
                           initialSpringVelocity: 0.3, options: [.curveEaseOut]) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            alpha = 1
            transform = .identity
        }
    }
}