import UIKit

/// What the SDK watches in the host app, armed by ``Groundcover/start(_:)`` with the hooks the
/// configuration leaves on, and disarmed by ``GroundcoverRumTesting/reset()``. Nothing is armed for
/// a session the sampling verdict left out. Every observer runs on the main thread and hands its
/// capture to the core queue.
final class Instrumentation {
    static let shared = Instrumentation()

    private var lifecycle: HostLifecycleObserver?
    private var textFields: TextFieldObserver?

    func arm(_ config: GroundcoverConfig, runtime: RumRuntime) {
        onMain { self.armOnMain(config, runtime: runtime) }
    }

    func disarm() {
        onMain { self.disarmOnMain() }
    }

    private func armOnMain(_ config: GroundcoverConfig, runtime: RumRuntime) {
        disarmOnMain()
        lifecycle = HostLifecycleObserver(initialState: UIApplication.shared.applicationState) {
            state in
            runtime.dispatch("lifecycle") { $0.lifecycle(state) }
        }
        let hooks = config.options.hooks
        let screens = ScreenTracker.shared
        if hooks.viewControllers { screens.install() }
        screens.tracksViewControllers = hooks.viewControllers
        screens.tracking = true
        screens.onScreen = { name, key in
            runtime.dispatch("screen") { $0.submit(.navigation(.screen(name: name, key: key))) }
        }
        let submit: (InteractionCapture) -> Void = { capture in
            var stamped = capture
            stamped.timestampNs = msToNs(runtime.nowMs)
            runtime.dispatch("interaction") { $0.submit(.interaction(stamped)) }
        }
        if hooks.textFields {
            textFields = TextFieldObserver(report: submit)
        }
        if hooks.urlSession {
            URLSessionTaskObserver.shared.install()
            URLSessionTaskObserver.shared.arm(runtime)
        }
        if hooks.touches {
            let touches = TouchObserver.shared
            touches.install()
            touches.onTap = { [weak self] window, point in
                self?.textFields?.tapped(at: point, in: window)
            }
            touches.onPresence = {
                runtime.dispatch("presence") { $0.presence() }
            }
            touches.onInteraction = submit
        }
    }

    private func disarmOnMain() {
        lifecycle?.stop()
        lifecycle = nil
        textFields?.stop()
        textFields = nil
        TouchObserver.shared.disarm()
        ScreenTracker.shared.disarm()
        URLSessionTaskObserver.shared.disarm()
    }

    /// `Groundcover.stopNavigationTracking`: the automatic screen sources report nothing more.
    func stopNavigationTracking() {
        onMain { ScreenTracker.shared.tracking = false }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
