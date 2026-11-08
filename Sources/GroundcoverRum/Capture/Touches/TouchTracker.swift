import Foundation

/// One touch's phase, as the tracker reads it.
enum TouchPhase {
    case began, moved, ended, cancelled
}

/// One touch at one moment: points in its window, and a monotonic time in milliseconds.
struct TouchSample {
    var id: ObjectIdentifier
    var phase: TouchPhase
    var x: Double
    var y: Double
    var timeMs: Double
}

/// A finished touch sequence, from the first finger down to the last one up. Its positions are the
/// first finger's: the one a tap or a drag is about.
struct TouchSequence {
    var startX: Double
    var startY: Double
    var endX: Double
    var endY: Double
    var startMs: Double
    var endMs: Double

    /// The most fingers down at once.
    var pointerCount: Int

    /// The farthest the first finger got from where it went down.
    var maxTravel: Double

    /// The system cancelled a touch (an incoming call, a system gesture), rather than a finger
    /// lifting.
    var cancelled: Bool

    /// The first finger's speed at release, points per second, over its last ~100 ms.
    var releaseVelocityX: Double = 0
    var releaseVelocityY: Double = 0

    /// How far apart the first two fingers were when both were first down, and when one of them
    /// lifted: a pinch's measure.
    var startSpread: Double = 0
    var endSpread: Double = 0

    var durationMs: Double { max(0, endMs - startMs) }

    /// Start to end, straight.
    var distance: Double {
        let dx = endX - startX
        let dy = endY - startY
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// What a finished sequence was, by RN's and Flutter's thresholds: within 10 points of touch-down,
/// one finger, a tap up to 500 ms and a long press after; two fingers, a pinch; a single finger
/// that travelled 32 points or more, a scroll or a swipe by the engine's classifier.
enum TouchClassifier {
    static let tapSlopDp: Double = 10
    static let tapMaxMs: Double = 500

    struct Result {
        var kind: InteractionKind
        var gesture: GestureMeasure?
    }

    static func classify(_ sequence: TouchSequence) -> Result? {
        let durationMs = Int(sequence.durationMs.rounded())
        if sequence.pointerCount >= 2 {
            let spread = abs(sequence.endSpread - sequence.startSpread)
            let seconds = sequence.durationMs / 1000
            return Result(
                kind: .pinch,
                gesture: GestureMeasure(
                    distanceDp: Int(spread.rounded()),
                    velocityDpS: seconds > 0 ? Int((spread / seconds).rounded()) : 0,
                    durationMs: durationMs, pointerCount: sequence.pointerCount,
                    partial: sequence.cancelled))
        }
        if sequence.maxTravel <= tapSlopDp {
            if sequence.cancelled { return nil }
            if sequence.durationMs <= tapMaxMs { return Result(kind: .tap) }
            return Result(
                kind: .longPress,
                gesture: GestureMeasure(
                    distanceDp: Int(sequence.distance.rounded()), velocityDpS: 0,
                    durationMs: durationMs, pointerCount: 1))
        }
        guard
            let movement = GCRumGestureClassifier.classify(
                startX: sequence.startX, startY: sequence.startY, endX: sequence.endX,
                endY: sequence.endY, velocityX: sequence.releaseVelocityX,
                velocityY: sequence.releaseVelocityY, pointerCount: 1)
        else { return nil }
        return Result(
            kind: movement.kind == "swipe" ? .swipe : .scroll,
            gesture: GestureMeasure(
                direction: GestureDirection(rawValue: movement.direction),
                distanceDp: Int(movement.distanceDp.rounded()),
                velocityDpS: Int(movement.velocityDpS.rounded()), durationMs: durationMs,
                pointerCount: 1, partial: sequence.cancelled))
    }
}

/// Follows the touches every window receives and reports when a sequence starts (the first finger
/// down: presence) and when it ends (the last one up). Main thread only.
final class TouchTracker {
    enum Edge {
        case began
        case ended(TouchSequence)
    }

    /// The window a release velocity is measured over, as UIKit's pan measures it.
    static let velocityWindowMs: Double = 100

    private struct Building {
        var sequence: TouchSequence
        var primary: ObjectIdentifier
        var down: Set<ObjectIdentifier>

        /// The second finger, for a pinch's spread.
        var secondary: ObjectIdentifier?
        var secondaryX = 0.0
        var secondaryY = 0.0

        /// The first finger's recent positions, for its release velocity.
        var recent: [(x: Double, y: Double, t: Double)] = []
    }

    private var building: Building?

    /// Feeds one event's touches, in order; returns the edges they crossed.
    func process(_ samples: [TouchSample]) -> [Edge] {
        var edges: [Edge] = []
        for sample in samples {
            if let edge = process(sample) { edges.append(edge) }
        }
        return edges
    }

    private func process(_ sample: TouchSample) -> Edge? {
        switch sample.phase {
        case .began:
            if var current = building {
                current.down.insert(sample.id)
                current.sequence.pointerCount = max(
                    current.sequence.pointerCount, current.down.count)
                if current.secondary == nil {
                    current.secondary = sample.id
                    current.secondaryX = sample.x
                    current.secondaryY = sample.y
                    current.sequence.startSpread = spread(current)
                    current.sequence.endSpread = current.sequence.startSpread
                }
                building = current
                return nil
            }
            building = Building(
                sequence: TouchSequence(
                    startX: sample.x, startY: sample.y, endX: sample.x, endY: sample.y,
                    startMs: sample.timeMs, endMs: sample.timeMs, pointerCount: 1, maxTravel: 0,
                    cancelled: false),
                primary: sample.id, down: [sample.id], recent: [(sample.x, sample.y, sample.timeMs)]
            )
            return .began
        case .moved:
            guard var current = building else { return nil }
            if current.secondary == sample.id {
                current.secondaryX = sample.x
                current.secondaryY = sample.y
            } else if current.primary == sample.id {
                moved(&current, to: sample)
            } else {
                return nil
            }
            if current.down.count >= 2 { current.sequence.endSpread = spread(current) }
            building = current
            return nil
        case .ended, .cancelled:
            guard var current = building, current.down.contains(sample.id) else { return nil }
            if current.primary == sample.id {
                moved(&current, to: sample)
                let velocity = releaseVelocity(current.recent)
                current.sequence.releaseVelocityX = velocity.x
                current.sequence.releaseVelocityY = velocity.y
            }
            if sample.phase == .cancelled { current.sequence.cancelled = true }
            current.down.remove(sample.id)
            guard current.down.isEmpty else {
                building = current
                return nil
            }
            building = nil
            return .ended(current.sequence)
        }
    }

    /// Forgets a sequence in flight: arming or disarming midway must not report half of one, and
    /// one whose end was lost must not swallow the next.
    func reset() {
        building = nil
    }

    private func moved(_ current: inout Building, to sample: TouchSample) {
        current.sequence.endX = sample.x
        current.sequence.endY = sample.y
        current.sequence.endMs = sample.timeMs
        current.sequence.maxTravel = max(
            current.sequence.maxTravel, travel(current.sequence, sample))
        current.recent.append((sample.x, sample.y, sample.timeMs))
        let cutoff = sample.timeMs - Self.velocityWindowMs
        while current.recent.count > 2, let first = current.recent.first, first.t < cutoff {
            current.recent.removeFirst()
        }
    }

    /// From the oldest position in the window to the release; zero when they share a time.
    private func releaseVelocity(_ recent: [(x: Double, y: Double, t: Double)]) -> (
        x: Double, y: Double
    ) {
        guard let first = recent.first, let last = recent.last, last.t > first.t else {
            return (0, 0)
        }
        let seconds = (last.t - first.t) / 1000
        return ((last.x - first.x) / seconds, (last.y - first.y) / seconds)
    }

    private func spread(_ current: Building) -> Double {
        let dx = current.secondaryX - current.sequence.endX
        let dy = current.secondaryY - current.sequence.endY
        return (dx * dx + dy * dy).squareRoot()
    }

    private func travel(_ sequence: TouchSequence, _ sample: TouchSample) -> Double {
        let dx = sample.x - sequence.startX
        let dy = sample.y - sequence.startY
        return (dx * dx + dy * dy).squareRoot()
    }
}
