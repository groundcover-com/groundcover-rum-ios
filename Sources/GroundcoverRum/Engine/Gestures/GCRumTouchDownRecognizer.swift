#if canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The gesture tracker's touch-down clock: reports where a touch sequence's first finger landed,
/// then FAILS in the same call, so it never recognizes anything.
///
/// A recognizer that RECOGNIZES on every touch (a `UILongPressGestureRecognizer` with
/// `minimumPressDuration = 0`) would take part in every tap rather than observe it, and
/// `cancelsTouchesInView = false` does not change that. React Native's root touch handler requires
/// every recognizer outside its own subtree to fail before it proceeds, and code that reacts to ANY
/// recognizer activating would cancel taps: react-native-gesture-handler before 2.13 cancels every
/// JavaScript responder when its root recognizer is asked whether another can prevent it, so a tap
/// would reach JavaScript as `touchStart` then `touchCancel`, with no `onPress`.
///
/// A recognizer that fails at touch-down settles any failure requirement on it at once and is never
/// the preventing side of a pair, so nothing is ever told one of ours activated. Failed recognizers
/// are not sent actions, hence the closure rather than a target.
final class GCRumTouchDownRecognizer: UIGestureRecognizer {
    private let onTouchDown: (UIView, CGPoint) -> Void

    init(onTouchDown: @escaping (UIView, CGPoint) -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        // Same observer settings as the tracker's pan.
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Read before failing. Once failed this recognizer sees nothing more until every finger is
        // up and UIKit resets it, so it fires once per sequence — as a zero-delay long press would.
        if let view {
            onTouchDown(view, location(in: view))
        }
        state = .failed
    }
}
#endif
