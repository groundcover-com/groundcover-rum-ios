import UIKit

/// Reads every touch the app receives, from one swizzle of `UIApplication.sendEvent(_:)` that
/// calls the original first and only then looks. It attaches no gesture recognizer, so it takes no
/// part in deciding which gesture wins and can't cancel anyone's touches. Per touch phase it does a
/// dictionary update; it names a target once per sequence, when the first finger goes down. Main
/// thread only.
final class TouchObserver {
    static let shared = TouchObserver()

    /// Presence: the first finger went down.
    var onPresence: (() -> Void)?

    /// A finished sequence that classified as an interaction.
    var onInteraction: ((InteractionCapture) -> Void)?

    /// A tap landed at a point of a window: a text field being edited elsewhere is done with.
    var onTap: ((UIWindow, CGPoint) -> Void)?

    private let tracker = TouchTracker()
    private var installed = false

    /// Where the first finger went down: the view UIKit delivered it to, and its window.
    private weak var touchedView: UIView?
    private weak var touchedWindow: UIWindow?

    /// What the first finger went down on.
    private var downTarget: InteractionTarget?

    /// The touches that went down as keystrokes (``isKeystroke(_:responder:)``), until each ends.
    private var keystrokes: Set<ObjectIdentifier> = []

    /// The first responder, whose input accessory view is the app's own in the keyboard's window.
    /// A test process has no scene for ``firstResponder()`` to find it through, so a test names it.
    var findFirstResponder: () -> UIResponder? = TouchObserver.firstResponder

    /// Installs the swizzle, once per process. It is never removed: whoever swizzled after us calls
    /// it, so it stays and goes quiet when ``disarm()`` clears the callbacks.
    func install() {
        guard !installed else { return }
        installed = true
        let selector = #selector(UIApplication.sendEvent(_:))
        typealias SendEvent = @convention(c) (AnyObject, Selector, UIEvent) -> Void
        _ = Swizzle.replace(UIApplication.self, selector, signature: "v@:@") { previous in
            let original = unsafeBitCast(previous, to: SendEvent.self)
            let replacement: @convention(block) (AnyObject, UIEvent) -> Void = { app, event in
                original(app, selector, event)
                TouchObserver.shared.handle(event)
            }
            return replacement
        }
    }

    func disarm() {
        onPresence = nil
        onInteraction = nil
        onTap = nil
        tracker.reset()
        touchedView = nil
        touchedWindow = nil
        downTarget = nil
        keystrokes = []
    }

    func handle(_ event: UIEvent) {
        guard onPresence != nil || onInteraction != nil, event.type == .touches,
            let touches = event.allTouches, !touches.isEmpty
        else { return }
        // Only fingers going down: none was down before, so a sequence still open lost its end on
        // the way, and is dropped, as Android's first finger down drops one.
        if touches.allSatisfy({ $0.phase == .began }) { tracker.reset() }
        var samples: [TouchSample] = []
        var began: [ObjectIdentifier: UITouch] = [:]
        for touch in touches {
            guard let phase = phase(of: touch) else { continue }
            let id = ObjectIdentifier(touch)
            // A keystroke is presence, never a tap, whose position would spell what was typed.
            // Decided once, when the touch goes down.
            if phase == .began {
                if Self.isKeystroke(touch, responder: findFirstResponder()) {
                    keystrokes.insert(id)
                } else {
                    keystrokes.remove(id)
                }
            }
            if keystrokes.contains(id) {
                if phase == .began { onPresence?() }
                if phase == .ended || phase == .cancelled { keystrokes.remove(id) }
                continue
            }
            let point = touch.location(in: touch.window)
            if phase == .began { began[id] = touch }
            samples.append(
                TouchSample(
                    id: id, phase: phase, x: Double(point.x), y: Double(point.y),
                    timeMs: touch.timestamp * 1000))
        }
        // Began first, so a finger that lands and lifts within one event still starts a sequence.
        samples.sort { order($0.phase) < order($1.phase) }
        for sample in samples {
            for edge in tracker.process([sample]) {
                switch edge {
                case .began:
                    let touch = began[sample.id]
                    touchedView = touch?.view
                    touchedWindow = touch?.window
                    onPresence?()
                    // Named now: by the time a drag ends, the content under its start has moved,
                    // and UIKit has let go of the SwiftUI gesture that names a button.
                    if onInteraction != nil, let touch, let window = touch.window {
                        downTarget = SwiftUIGestures.named(
                            TargetResolver.resolve(
                                touchedView: touch.view, window: window,
                                point: CGPoint(x: sample.x, y: sample.y)),
                            recognizerNames: (touch.gestureRecognizers ?? []).lazy.map(\.name),
                            description: { String(describing: touch) })
                    }
                case .ended(let sequence):
                    finish(sequence)
                }
            }
        }
    }

    private func finish(_ sequence: TouchSequence) {
        defer {
            touchedView = nil
            touchedWindow = nil
            downTarget = nil
        }
        guard let window = touchedWindow, let result = TouchClassifier.classify(sequence) else {
            return
        }
        let end = CGPoint(x: sequence.endX, y: sequence.endY)
        if result.kind == .tap { onTap?(window, end) }
        guard let onInteraction else { return }
        // A tap is where the finger lifted; a gesture is about what it went down on, named when
        // it went down.
        let point = result.kind == .tap ? end : CGPoint(x: sequence.startX, y: sequence.startY)
        let target =
            downTarget
            ?? TargetResolver.resolve(touchedView: touchedView, window: window, point: point)
        onInteraction(
            InteractionCapture(
                kind: result.kind, target: target, x: Double(point.x), y: Double(point.y),
                gesture: result.gesture))
    }

    /// Whether `touch` went down as a keystroke: presence, never a tap, whose position would spell
    /// what was typed. The keyboard's window (`UIRemoteKeyboardWindow`), in the app's process on
    /// some releases, holds the system keyboard and its prediction bar, the first responder's input
    /// view (a custom keypad) and its input accessory view. Only a touch inside the accessory view,
    /// the app's own (a composer's Send, a toolbar's Done), is a tap like any other; anything else
    /// there is a keystroke, so a view the SDK doesn't know, such as a prediction naming the word
    /// being typed, is never read. `responder` is read only for a touch in that window.
    static func isKeystroke(_ touch: UITouch, responder: @autoclosure () -> UIResponder?) -> Bool {
        guard let window = touch.window, NSStringFromClass(type(of: window)).contains("Keyboard")
        else { return false }
        guard let accessory = responder()?.inputAccessoryView, let view = touch.view else {
            return true
        }
        return !view.isDescendant(of: accessory)
    }

    /// The first responder, which an action sent to no target goes to, through the key window.
    static func firstResponder() -> UIResponder? {
        foundFirstResponder = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.groundcoverFoundFirstResponder(_:)), to: nil, from: nil, for: nil)
        return foundFirstResponder
    }

    /// Where the action ``firstResponder()`` sends leaves the responder it reached.
    fileprivate static weak var foundFirstResponder: UIResponder?

    private func phase(of touch: UITouch) -> TouchPhase? {
        switch touch.phase {
        case .began: return .began
        case .moved: return .moved
        case .ended: return .ended
        case .cancelled: return .cancelled
        default: return nil
        }
    }

    private func order(_ phase: TouchPhase) -> Int {
        switch phase {
        case .began: return 0
        case .moved: return 1
        case .ended, .cancelled: return 2
        }
    }
}

extension UIResponder {
    /// The action ``TouchObserver`` sends to no target, to find the first responder.
    @objc fileprivate func groundcoverFoundFirstResponder(_ sender: Any?) {
        TouchObserver.foundFirstResponder = self
    }
}
