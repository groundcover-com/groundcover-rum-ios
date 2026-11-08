import Foundation

/// Decides what a finished pan actually was.
///
/// Kept apart from [GCRumGestureTracker] because none of this needs UIKit — it is
/// arithmetic on two points and a velocity — and because getting it wrong is
/// silent: a mis-signed axis reports every scroll as its opposite, which no
/// crash and no test asserting only "some direction" would catch.
enum GCRumGestureClassifier {
    /// Below this a drag is a wobble, not a gesture worth reporting.
    static let minDistanceDp: Double = 32

    /// A flick released with real momentum is a swipe; a slower drag that came
    /// to rest is a scroll. The user's intent differs and so does what they
    /// expect to happen next.
    static let swipeVelocityDpS: Double = 300

    struct Result: Equatable {
        let kind: String
        let direction: String
        let distanceDp: Double
        let velocityDpS: Double
    }

    /// - Parameter pointerCount: the most simultaneous touches the sequence reached. Two or more is
    ///   a pinch, which this classifier does not produce — see below.
    /// - Returns: the classified gesture, or nil when the movement was too small
    ///   to be one, or when it was not a single-finger movement at all.
    static func classify(
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        velocityX: Double,
        velocityY: Double,
        pointerCount: Int
    ) -> Result? {
        // A pinch is JavaScript's to report: this classifier only ever answers "swipe" or "scroll",
        // and JS suppression covers exactly those two kinds — a `pinch` is never suppressed, because
        // JS's numbers are all there are for one. So emitting a two-finger drag as a `scroll` here
        // does not mislabel one event, it produces TWO for the same gesture: a native `scroll` and
        // an unsuppressed JS `pinch`. Declining is what keeps the pair mutually exclusive.
        guard pointerCount < 2 else { return nil }

        let dx = endX - startX
        let dy = endY - startY
        let distanceDp = (dx * dx + dy * dy).squareRoot()
        guard distanceDp >= minDistanceDp else { return nil }

        let velocityDpS = (velocityX * velocityX + velocityY * velocityY).squareRoot()

        return Result(
            kind: velocityDpS >= swipeVelocityDpS ? "swipe" : "scroll",
            direction: direction(dx: dx, dy: dy),
            distanceDp: distanceDp,
            velocityDpS: velocityDpS
        )
    }

    /// Gestures are reported along their dominant axis; a diagonal drag is
    /// whichever way it mostly went.
    ///
    /// Note the sign convention: this takes UIKit/Android screen coordinates,
    /// where y grows DOWNWARD. A positive dy is therefore "down".
    static func direction(dx: Double, dy: Double) -> String {
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? "right" : "left"
        }
        return dy >= 0 ? "down" : "up"
    }
}
