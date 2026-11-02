import XCTest
import UIKit
@testable import Xtend

@MainActor
final class SceneLifecycleTests: XCTestCase {
    func testAppConfiguresWindowSceneLifecycle() {
        let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        let configurations = manifest?["UISceneConfigurations"] as? [String: Any]
        let windowScenes = configurations?["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]

        XCTAssertEqual(manifest?["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        XCTAssertEqual(windowScenes?.first?["UISceneDelegateClassName"] as? String, "Xtend.SceneDelegate")
    }

    func testSceneDelegateStartsWithoutWindow() {
        XCTAssertNil(SceneDelegate().window)
    }
}
