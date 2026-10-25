import UIKit

/// A local-only developer aid. Off by default and independent of extension reloads.
enum DeveloperOptions {
    static let showTouchesKey = "xtend.developer.showTouches"

    static var showsTouches: Bool {
        get { UserDefaults.standard.bool(forKey: showTouchesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showTouchesKey) }
    }
}

/// Observes UIKit touches *after* normal event delivery, so the overlay never
/// competes with WKWebView, native edge swipes, scroll views or button gestures.
@MainActor
final class TouchVisualizationWindow: UIWindow {
    private var touchOverlay: TouchOverlayView?

    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)

        guard DeveloperOptions.showsTouches else {
            touchOverlay?.removeFromSuperview()
            touchOverlay = nil
            return
        }
        guard let touches = event.allTouches, !touches.isEmpty else { return }

        let overlay: TouchOverlayView
        if let existing = touchOverlay, existing.superview === self {
            overlay = existing
        } else {
            let created = TouchOverlayView(frame: bounds)
            created.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            created.isUserInteractionEnabled = false
            created.accessibilityElementsHidden = true
            addSubview(created)
            touchOverlay = created
            overlay = created
        }
        bringSubviewToFront(overlay)
        overlay.update(touches, in: self)
    }
}

/// The overlay never receives hit tests. Each touch has its own marker and
/// bounded trail; ended/cancelled gestures fade out automatically.
@MainActor
final class TouchOverlayView: UIView {
    private var active: [ObjectIdentifier: TouchMarkerView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    func update(_ touches: Set<UITouch>, in window: UIWindow) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let point = touch.location(in: window)
            switch touch.phase {
            case .began:
                let marker = TouchMarkerView(frame: bounds)
                marker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                marker.isUserInteractionEnabled = false
                marker.accessibilityElementsHidden = true
                addSubview(marker)
                marker.move(to: point)
                active[key] = marker
            case .moved:
                active[key]?.move(to: point)
            case .ended, .cancelled:
                guard let marker = active.removeValue(forKey: key) else { continue }
                marker.move(to: point)
                UIView.animate(withDuration: 0.45, delay: 0.08,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    marker.alpha = 0
                } completion: { _ in
                    marker.removeFromSuperview()
                }
            case .stationary, .regionEntered, .regionMoved, .regionExited:
                break
            @unknown default:
                break
            }
        }
    }
}

@MainActor
private final class TouchMarkerView: UIView {
    private let trail = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var points: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        trail.strokeColor = UIColor.systemYellow.cgColor
        trail.lineWidth = 5
        trail.lineCap = .round
        trail.lineJoin = .round
        trail.fillColor = nil
        trail.shadowColor = UIColor.black.cgColor
        trail.shadowOpacity = 0.65
        trail.shadowRadius = 2
        trail.shadowOffset = .zero
        layer.addSublayer(trail)

        dot.path = UIBezierPath(ovalIn: CGRect(x: -17, y: -17, width: 34, height: 34)).cgPath
        dot.fillColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 3
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.65
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        layer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func move(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 2 { return }
        points.append(point)
        if points.count > 100 { points.removeFirst(points.count - 100) }
        let path = UIBezierPath()
        if let start = points.first {
            path.move(to: start)
            for next in points.dropFirst() { path.addLine(to: next) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trail.path = path.cgPath
        dot.position = point
        CATransaction.commit()
    }
}
