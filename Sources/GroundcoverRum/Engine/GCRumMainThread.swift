import Foundation

/// Runs work on the main thread. The engine is armed from `nativeInit`, which RN
/// dispatches on a background queue (correctly, since arming does disk I/O) — but a
/// `Timer` or `CADisplayLink` added to `RunLoop.main` from another thread may never fire,
/// which would leave the hang watchdog waiting forever for a heartbeat that never beats.
/// `UIApplication.shared`, `UIScreen.main` and `addGestureRecognizer` are main-only too.
///
/// Executing inline when already on main matters: callers use this during `start()` and
/// expect the tracker armed when it returns.
enum GCRumMainThread {
    static func run(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
