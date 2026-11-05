import UIKit

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private static let openedXKey = "xtend.hasOpenedX"

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Only personal builds include PreinstalledExtensions. Normal builds do nothing.
        _ = BundledExtensionInstaller.installIfPresent()
        let window = UIWindow(windowScene: windowScene)
        if UserDefaults.standard.bool(forKey: Self.openedXKey) {
            window.rootViewController = BrowserViewController()
        } else {
            window.rootViewController = ExtensionWelcomeViewController { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.openedXKey)
                guard let window = self?.window else { return }
                UIView.transition(with: window, duration: 0.35, options: .transitionCrossDissolve) {
                    window.rootViewController = BrowserViewController()
                }
            }
        }
        self.window = window
        window.makeKeyAndVisible()
    }
}
