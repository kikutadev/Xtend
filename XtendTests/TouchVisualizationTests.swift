import XCTest
import UIKit
@testable import Xtend

@MainActor
final class TouchVisualizationTests: XCTestCase {
    func testTouchDisplayPreferenceIsOffByDefaultAndPersists() {
        let key = DeveloperOptions.showTouchesKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(DeveloperOptions.showsTouches)
        DeveloperOptions.showsTouches = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        XCTAssertTrue(DeveloperOptions.showsTouches)
        DeveloperOptions.showsTouches = false
        XCTAssertFalse(DeveloperOptions.showsTouches)
    }

    func testOverlayCannotInterceptTouches() {
        let overlay = TouchOverlayView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertFalse(overlay.point(inside: CGPoint(x: 100, y: 100), with: nil))
    }

    func testAppUsesTouchVisualizationWindow() {
        XCTAssertTrue(AppDelegate().window == nil)
        let window = TouchVisualizationWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertTrue(window is UIWindow)
    }
}
