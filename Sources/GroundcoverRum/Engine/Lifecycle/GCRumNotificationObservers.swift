import Foundation

/// A bag of NotificationCenter registrations that can actually be given back. The block-based
/// `addObserver(forName:object:queue:using:)` does NOT register `self` — it returns an opaque
/// token that is the only handle able to remove it, so the natural-looking
/// `removeObserver(self)` in a `stop()` silently unregisters nothing and every start/stop cycle
/// leaves handlers on the process-wide center forever. The mistake is invisible: teardown reads
/// correct and compiles, and the leak only shows as handlers firing after their owner is gone.
///
/// Foundation only, deliberately — notification NAMES come from the caller, so this type needs
/// no UIKit and can be tested without an app.
final class GCRumNotificationObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// Registers `handler` for `name`, keeping the token needed to undo it.
    func observe(_ name: Notification.Name, using handler: @escaping () -> Void) {
        tokens.append(
            center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
        )
    }

    /// Unregisters everything this bag registered. Idempotent.
    ///
    /// By TOKEN — `removeObserver(self)` is the trap this type exists to close,
    /// since `self` was never the registered observer.
    func removeAll() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}
