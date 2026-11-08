import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Observes scrolls and swipes at the window level, via a `UIPanGestureRecognizer`, so the
/// engine needs no swizzle of the event entry point (`UIApplication.sendEvent`).
///
/// A window recognizer is not automatically a bystander, though. React Native's root touch
/// handler requires every recognizer outside its subtree to FAIL before it proceeds, so one of
/// ours that recognizes can cost JavaScript its touch — see `GCRumTouchDownRecognizer`, which is
/// why the touch-down clock is built to only ever fail.
///
/// Attaches per WINDOW: a React Native `Modal` renders in its own UIWindow, so a single
/// key-window recognizer goes blind whenever a modal is up.
final class GCRumGestureTracker: NSObject {
    struct Gesture {
        let kind: String
        /// Touch-DOWN time. JavaScript matches its own touch history against
        /// this, so it must be when the finger LANDED, not when the recognizer
        /// finally began — which lags by the slop and any pause before the drag.
        let startedAtMs: Double
        let endedAtMs: Double
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        let direction: String
        let distanceDp: Double
        let velocityDpS: Double
        let pointerCount: Int
    }

    private let onGesture: (Gesture) -> Void
    /// Keyed by window IDENTITY and holding each window weakly — see
    /// `GCRumAttachmentRegistry`, which is where the reason lives and where it is
    /// tested. A plain `[ObjectIdentifier: …]` here would answer "already attached"
    /// about windows it had never seen, because addresses get reused.
    private let recognizers = GCRumAttachmentRegistry<UIPanGestureRecognizer>()
    /// In-flight pan state, one entry per VIEW rather than one set of scalars per tracker — see
    /// `GCRumPanSequences`, where the reason lives and where it is tested. Keyed by the view both
    /// recognizers share, so a window's touch-down clock and its pan cannot be claimed by another
    /// window's gesture. Android is per-recognizer too.
    private let sequences = GCRumPanSequences<ObjectIdentifier>()

    #if canImport(UIKit)
    /// Attached alongside the pan, purely as a clock: it reports the instant the finger
    /// lands. The pan cannot supply that — it only begins once the slop is crossed, which
    /// is after however long the user pressed and held first.
    private let touchDownRecognizers = GCRumAttachmentRegistry<GCRumTouchDownRecognizer>()
    #endif
    // The touch-down time and point — and the staleness rule that decides whether to trust them —
    // live per view in `sequences`, alongside the rest of the in-flight state.

    /// Fired the first time a real `UIWindow` is actually hooked.
    ///
    /// JavaScript stands its own classifier down for scroll and swipe only once it
    /// has heard this. It cannot use the arming status instead: `attach(to:)` runs
    /// on the main queue (`addGestureRecognizer` is main-thread-only) while the
    /// engine arms off it, so `status.gestures` is true well before any recognizer
    /// exists — and stays true even when no window ever turns up to attach to.
    /// TRUE, and it is a statement about this tracker rather than about iOS.
    ///
    /// Attachment is driven by `UIWindow.didBecomeKeyNotification` plus a sweep of
    /// `connectedScenes`, so the unit of coverage is a WINDOW — and a React Native `Modal` renders
    /// into its own `UIWindow`. There is no surface the app can present that this misses.
    ///
    /// Rides on the `gestures_attached` signal because JavaScript cannot infer it and must not
    /// guess. The Android twin attaches per ACTIVITY, cannot reach a `Dialog`, and answers false;
    /// told only "attached", JS would stand down app-wide there and a modal drag would be measured
    /// by nobody.
    static let coversAllSurfaces = true

    private let onAttached: () -> Void

    /// Whether any window is hooked right now. Written on the main queue alongside the recognizer
    /// maps, but read from whichever queue answers a re-init, so it cannot rely on the main-queue
    /// confinement those maps do. Same `NSLock` shape as the app-start tracker and the hang
    /// watchdog.
    private let attachedLock = NSLock()
    private var attachedFlag = false

    /// For a JavaScript context that arrived AFTER the attach. ``onAttached`` is edge-triggered and
    /// a second `start` on an already-started engine returns early without re-attaching, so the
    /// edge cannot be replayed — which is every Metro fast-refresh. Unreported, the reloaded
    /// context would suppress nothing while this tracker kept measuring, and each gesture would be
    /// reported twice under the same attribute names.
    var isAttached: Bool {
        attachedLock.lock()
        defer { attachedLock.unlock() }
        return attachedFlag
    }

    private func setAttached(_ value: Bool) {
        attachedLock.lock()
        attachedFlag = value
        attachedLock.unlock()
    }

    init(onAttached: @escaping () -> Void = {}, onGesture: @escaping (Gesture) -> Void) {
        self.onAttached = onAttached
        self.onGesture = onGesture
        super.init()
    }

    /// `UIApplication.shared` and `addGestureRecognizer` are main-thread-only,
    /// and the engine arms off-main — hence the hop. Without it the recognizer
    /// silently fails to attach and no gesture is ever measured.
    func start() {
        #if canImport(UIKit)
        GCRumMainThread.run { [weak self] in
            guard let self else { return }
            self.attachToExistingWindows()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleWindowBecameKey(_:)),
                name: UIWindow.didBecomeKeyNotification,
                object: nil
            )
        }
        #endif
    }

    func stop() {
        #if canImport(UIKit)
        // Eagerly, not inside the hop below: the unhook is dispatched to main, and until it runs a
        // re-init asking `isAttached` would be told yes by a tracker being torn down. Answering no
        // early only ever leaves JavaScript in charge of its own capture.
        setAttached(false)
        GCRumMainThread.run { [weak self] in
            guard let self else { return }
            NotificationCenter.default.removeObserver(self)
            for recognizer in self.recognizers.allValues() {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            self.recognizers.removeAll()
            for recognizer in self.touchDownRecognizers.allValues() {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            self.touchDownRecognizers.removeAll()
            self.sequences.removeAll()
            // AGAIN, and not redundantly: the eager clear above runs on whichever queue armed the
            // engine, and main stays free to deliver a `didBecomeKeyNotification` before this hop
            // gets its turn. `attachToWindow` sets the flag on every attach, so it can be back to
            // true by the time we arrive here — with the recognizers about to be removed.
            //
            // JavaScript reads this across the bridge on re-init and stands its own swipe/scroll
            // classifier down on the strength of it, so a stale `true` means nothing measures
            // movement at all. The Android twin recomputes the same fact at the same point.
            self.setAttached(false)
        }
        #endif
    }

    #if canImport(UIKit)
    private func attachToExistingWindows() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        windows.forEach(attach(to:))
    }

    @objc private func handleWindowBecameKey(_ note: Notification) {
        guard let window = note.object as? UIWindow else { return }
        attach(to: window)
    }

    private func attach(to window: UIWindow) {
        guard !recognizers.contains(window) else { return }

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // Observer settings: the touches views receive are never cancelled or held back,
        // and this never waits for another recognizer to fail. It still RECOGNIZES once a
        // drag crosses the slop. React Native's own handler has begun by then and does not
        // care, but code that reacts to any recognizer activating still sees it —
        // react-native-gesture-handler before 2.13 cancels the drag's JS responder there.
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self

        window.addGestureRecognizer(recognizer)
        recognizers.set(recognizer, for: window)

        // Fails on every touch-down, so nothing ever waits on it — see the type.
        let touchDown = GCRumTouchDownRecognizer { [weak self] view, point in
            self?.recordTouchDown(on: view, at: point)
        }
        // Simultaneous with everything, so no recognizer that begins first can exclude it
        // before it has read the touch.
        touchDown.delegate = self

        window.addGestureRecognizer(touchDown)
        touchDownRecognizers.set(touchDown, for: window)
        setAttached(true)

        // Only now is anything actually observing touches. Announced on every
        // attach rather than once: JS's flag is idempotent, and a tracker that
        // re-attaches after a stop/start cycle has to be able to say so again.
        onAttached()
    }

    private func recordTouchDown(on view: UIView, at point: CGPoint) {
        sequences.recordTouchDown(
            ObjectIdentifier(view),
            atMs: Date().timeIntervalSince1970 * 1000,
            x: Double(point.x),
            y: Double(point.y)
        )
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let key = ObjectIdentifier(view)

        switch recognizer.state {
        case .began:
            // Start time and point come from touch-DOWN, not recognizer-begin, because JS records
            // its touch history at touch-down and correlateGesture matches on both
            // (CORRELATION_WINDOW_MS 150, CORRELATION_DISTANCE_DP 24). `.began` only fires once the
            // slop is crossed — on a press-then-drag that lags by however long the user held still,
            // and on a fast drag the finger is already ~30dp away — either of which ships the
            // gesture unlabelled. The freshness rule lives in GCRumPanSequences, where it is tested;
            // the values here are the fallback for a pan with no touch-down of its own.
            let point = recognizer.location(in: view)
            sequences.begin(
                key,
                nowMs: nowMs,
                x: Double(point.x),
                y: Double(point.y),
                pointers: recognizer.numberOfTouches
            )
        case .changed:
            sequences.observe(key, pointers: recognizer.numberOfTouches)
        case .ended, .cancelled:
            emit(recognizer, in: view, key: key, endedAtMs: nowMs)
        default:
            break
        }
    }

    private func emit(
        _ recognizer: UIPanGestureRecognizer,
        in view: UIView,
        key: ObjectIdentifier,
        endedAtMs: Double
    ) {
        // Consumed here: a sequence reports once. Nothing in flight means no `.began` was seen for
        // this view, and there is no geometry to report a gesture from.
        guard let sequence = sequences.end(key) else { return }

        let end = recognizer.location(in: view)
        let velocity = recognizer.velocity(in: view)

        // Everything judgemental — too small to report? swipe or scroll? which
        // way? — lives in the classifier, where it is unit-tested.
        guard let result = GCRumGestureClassifier.classify(
            startX: sequence.startX,
            startY: sequence.startY,
            endX: Double(end.x),
            endY: Double(end.y),
            velocityX: Double(velocity.x),
            velocityY: Double(velocity.y),
            pointerCount: sequence.maxPointers
        ) else { return }

        onGesture(
            Gesture(
                kind: result.kind,
                startedAtMs: sequence.startedAtMs,
                endedAtMs: endedAtMs,
                startX: sequence.startX,
                startY: sequence.startY,
                endX: Double(end.x),
                endY: Double(end.y),
                direction: result.direction,
                distanceDp: result.distanceDp,
                velocityDpS: result.velocityDpS,
                pointerCount: sequence.maxPointers
            )
        )
    }
    #endif
}

#if canImport(UIKit)
extension GCRumGestureTracker: UIGestureRecognizerDelegate {
    /// Never compete with the app's own recognizers — a scroll view must keep
    /// scrolling exactly as it would without us.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        return true
    }
}
#endif
