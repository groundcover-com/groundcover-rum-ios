import SwiftUI
import UIKit

/// Where SwiftUI's `groundcoverPrivate()` sits on screen. SwiftUI draws no view per control, so the
/// modifier puts an empty, untouchable view behind its content, and an element it overlaps, or a
/// touch inside it, is masked.
enum PrivateRegions {
    private static let markers = NSHashTable<PrivateMarkerView>.weakObjects()

    static func register(_ marker: PrivateMarkerView) {
        markers.add(marker)
    }

    static func unregister(_ marker: PrivateMarkerView) {
        markers.remove(marker)
    }

    /// Whether a private SwiftUI view in `window` overlaps `rect`, in `window`'s coordinates. A
    /// zero-size rect is a point: inside one, or not.
    static func overlap(_ rect: CGRect, in window: UIWindow) -> Bool {
        for marker in markers.allObjects
        where marker.window === window && marker.isPrivate && !isHidden(marker) {
            if marker.convert(marker.bounds, to: window).intersects(rect) { return true }
        }
        return false
    }

    private static func isHidden(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return true }
            current = candidate.superview
        }
        return false
    }
}

/// The view behind a private SwiftUI view: never touched, never read by VoiceOver.
final class PrivateMarkerView: UIView {
    var isPrivate = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            PrivateRegions.register(self)
        } else {
            PrivateRegions.unregister(self)
        }
    }
}

/// Puts a ``PrivateMarkerView`` behind its content.
struct PrivateMarker: UIViewRepresentable {
    let isPrivate: Bool

    func makeUIView(context: Context) -> PrivateMarkerView {
        let view = PrivateMarkerView(frame: .zero)
        view.isPrivate = isPrivate
        return view
    }

    func updateUIView(_ view: PrivateMarkerView, context: Context) {
        view.isPrivate = isPrivate
    }
}
