import Foundation

/// What one pan sequence accumulates between `.began` and `.ended`.
struct GCRumPanSequence: Equatable {
    var startX: Double
    var startY: Double
    var startedAtMs: Double
    var maxPointers: Int
}

/// In-flight pan state, held **one per recognizer** rather than once per tracker.
///
/// The tracker attaches a pan recognizer to every window it instruments, so a single set of
/// `startPoint` / `startedAtMs` / `maxPointers` scalars is shared by all of them. Two windows whose
/// gestures overlap then write over each other: a two-finger sequence in one window raises the
/// shared pointer count, and the other window's ordinary one-finger drag ends carrying it. Since
/// `GCRumGestureClassifier` declines a multi-pointer sequence, that drag is not merely mislabelled —
/// it is dropped, and no interaction is reported for a gesture the user actually made.
///
/// Android keeps this per recognizer too: its `maxPointers` lives on `GcRumGestureRecognizer`, one
/// of which is created per window.
///
/// A type of its own rather than a dictionary in the tracker because `GCRumGestureTracker` imports
/// UIKit, and anything living there cannot be tested without a UIKit host.
/// Generic over the key for the same reason: a test can use `Int` where the tracker uses
/// `ObjectIdentifier`. Same rationale as `GCRumGestureClassifier` and `GCRumAttachmentRegistry`.
final class GCRumPanSequences<Key: Hashable> {
    /// A touch-down remembered before its pan began. Kept separate: the touch-down recognizer
    /// reports as the finger lands, and the pan only `.began`s once slop is crossed — which can be
    /// much later, or never.
    private struct PendingTouchDown {
        let atMs: Double
        let x: Double
        let y: Double
    }

    private var touchDowns: [Key: PendingTouchDown] = [:]
    private var inFlight: [Key: GCRumPanSequence] = [:]

    /// Beyond this a remembered touch-down is stale — a leftover from a sequence whose pan never
    /// began — and the pan's own `.began` values are used instead.
    private let maxTouchDownAgeMs: Double

    init(maxTouchDownAgeMs: Double = 30_000) {
        self.maxTouchDownAgeMs = maxTouchDownAgeMs
    }

    func recordTouchDown(_ key: Key, atMs: Double, x: Double, y: Double) {
        touchDowns[key] = PendingTouchDown(atMs: atMs, x: x, y: y)
    }

    /// Opens a sequence. Start time and point come from this key's touch-down when one is fresh,
    /// because JS records its own touch history at touch-down and correlation matches on both — a
    /// `.began` point is already slop-distance away, which is enough to miss the match and ship the
    /// gesture unlabelled.
    ///
    /// - Parameters are the fallbacks used when no fresh touch-down is held.
    func begin(_ key: Key, nowMs: Double, x: Double, y: Double, pointers: Int) {
        let down = touchDowns[key]
        let age = down.map { nowMs - $0.atMs }
        let fresh = down != nil && age! >= 0 && age! <= maxTouchDownAgeMs

        inFlight[key] = GCRumPanSequence(
            startX: fresh ? down!.x : x,
            startY: fresh ? down!.y : y,
            startedAtMs: fresh ? down!.atMs : nowMs,
            maxPointers: max(1, pointers)
        )
    }

    /// Raises this sequence's pointer high-water mark. A no-op for a key with nothing in flight, so
    /// a `.changed` arriving after the end cannot resurrect one.
    func observe(_ key: Key, pointers: Int) {
        guard var sequence = inFlight[key] else { return }
        if pointers > sequence.maxPointers {
            sequence.maxPointers = pointers
            inFlight[key] = sequence
        }
    }

    /// Consumes the sequence: a second `.ended` for the same key reports nothing rather than
    /// re-emitting the previous gesture's geometry.
    func end(_ key: Key) -> GCRumPanSequence? {
        touchDowns.removeValue(forKey: key)
        return inFlight.removeValue(forKey: key)
    }

    /// Teardown. Windows are never detached individually — `stop()` unhooks them all at once — so
    /// this is the whole of the reclaim path. Without it a stop/start cycle would leave the previous
    /// run's half-finished sequences in the map, and a `.ended` arriving after the restart could
    /// report a gesture whose start belongs to the run before it.
    func removeAll() {
        touchDowns.removeAll()
        inFlight.removeAll()
    }

    var inFlightCount: Int { inFlight.count }
}
