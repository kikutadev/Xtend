import UIKit

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private static let openedXKey = "xtend.hasOpenedX"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
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
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
