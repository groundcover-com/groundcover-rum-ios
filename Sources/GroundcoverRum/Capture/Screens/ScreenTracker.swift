import ObjectiveC
import SwiftUI
import UIKit

/// Reports the screens the app shows: a view controller when it appears, from one swizzle of
/// `UIViewController.viewDidAppear(_:)` itself, and a SwiftUI view marked `.groundcoverScreen()`
/// when it appears. When a sheet is dismissed and nothing appears in its place, the screen under it,
/// which never disappeared, is current again, from a swizzle of `viewDidDisappear(_:)` and
/// SwiftUI's `onDisappear`. A screen that gives way to a view that isn't one (an unmarked SwiftUI
/// view, a hosting controller, one of Apple's) stays current. A view controller is a screen
/// when it isn't Apple's and holds none of the app's own nor a hosting controller: navigation,
/// tab, page, split and hosting controllers never are (an app's subclass of a hosting controller
/// included), nor is a controller around a hosting one, so a SwiftUI screen inside a hosting
/// controller is reported once, by the name the app gave it. Apple's other controllers inside one
/// (a player, a web view) leave it a screen. Main thread only.
final class ScreenTracker {
    static let shared = ScreenTracker()

    /// A screen became current: its name and this instance's key.
    var onScreen: ((String, String) -> Void)?

    /// Whether view controllers are reported (the `viewControllers` hook).
    var tracksViewControllers = false

    /// False after `stopNavigationTracking`: no automatic screen is reported.
    var tracking = true

    private var installed = false
    private var counters: [String: Int] = [:]

    /// The screens reported and not gone since, the current one last.
    private var shown: [Shown] = []

    /// Screens reported so far, so a disappearance can tell whether another appeared after it.
    private var reports = 0

    private struct Shown {
        weak var owner: AnyObject?
        let name: String
        let key: String
    }

    /// Installs the swizzles, once per process. They are never removed; they go quiet on
    /// ``disarm()``.
    func install() {
        guard !installed else { return }
        installed = true
        hook(#selector(UIViewController.viewDidAppear(_:))) {
            ScreenTracker.shared.viewControllerAppeared($0)
        }
        hook(#selector(UIViewController.viewDidDisappear(_:))) {
            ScreenTracker.shared.viewControllerDisappeared($0)
        }
    }

    /// Replaces one of UIViewController's own `(Bool) -> Void` appearance methods with one that
    /// calls the previous implementation, then `handle`.
    private func hook(_ selector: Selector, _ handle: @escaping (UIViewController) -> Void) {
        typealias Appearance = @convention(c) (AnyObject, Selector, Bool) -> Void
        _ = Swizzle.replace(UIViewController.self, selector, signature: "v@:B") { previous in
            let original = unsafeBitCast(previous, to: Appearance.self)
            let replacement: @convention(block) (AnyObject, Bool) -> Void = {
                controller, animated in
                original(controller, selector, animated)
                if let controller = controller as? UIViewController { handle(controller) }
            }
            return replacement
        }
    }

    func disarm() {
        onScreen = nil
        tracksViewControllers = false
        tracking = true
        shown = []
    }

    func viewControllerAppeared(_ controller: UIViewController) {
        guard tracking, tracksViewControllers, onScreen != nil, Self.isScreen(controller) else {
            return
        }
        let name = Self.screenName(of: controller)
        report(name, key(for: controller, name: name), owner: controller)
    }

    /// Only a dismissal, of the controller or a parent, uncovers a screen: after a push or a tab
    /// switch to a view that isn't a screen, the one that went is still the last reported.
    func viewControllerDisappeared(_ controller: UIViewController) {
        disappeared(controller, uncovering: Self.isBeingDismissed(controller))
    }

    /// A SwiftUI screen appeared; `instance` is its view's own token, so two copies of one screen
    /// get two keys and the same copy coming back keeps its key.
    func swiftUIScreenAppeared(name: String, key: String?, instance: ScreenInstance) {
        guard tracking, onScreen != nil, !name.isEmpty else { return }
        if instance.key == nil { instance.key = nextKey(name) }
        report(name, key ?? instance.key ?? name, owner: instance)
    }

    /// SwiftUI doesn't say why a view went, so any disappearance may uncover a screen, and the
    /// screen under it is checked for a sheet still over it instead.
    func swiftUIScreenDisappeared(_ instance: ScreenInstance) {
        disappeared(instance, uncovering: true)
    }

    private func report(_ name: String, _ key: String, owner: AnyObject) {
        shown.removeAll { $0.owner == nil || $0.owner === owner }
        shown.append(Shown(owner: owner, name: name, key: key))
        reports += 1
        onScreen?(name, key)
    }

    /// When the current screen went away `uncovering` the one under it, that one is current again
    /// if it is still on screen and nothing it presents still covers it, one main-loop turn later
    /// and only if no screen appeared meanwhile: a screen pushed in the turn its predecessor went
    /// is current, and the presenter must not flash in between.
    private func disappeared(_ owner: AnyObject, uncovering: Bool) {
        guard let index = shown.lastIndex(where: { $0.owner === owner }) else { return }
        shown.remove(at: index)
        guard uncovering, index == shown.count else { return }
        let reportsThen = reports
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reports == reportsThen, self.tracking, let onScreen = self.onScreen
            else { return }
            self.shown.removeAll { !Self.isOnScreen($0.owner) }
            if let top = self.shown.last, !Self.isCovered(top.owner) { onScreen(top.name, top.key) }
        }
    }

    /// A view controller whose view is in a window; a SwiftUI screen until its `onDisappear`.
    private static func isOnScreen(_ owner: AnyObject?) -> Bool {
        guard let owner else { return false }
        guard let controller = owner as? UIViewController else { return true }
        return controller.viewIfLoaded?.window != nil
    }

    /// Whether `controller` or a parent of it is being dismissed: a sheet, or a screen inside one.
    private static func isBeingDismissed(_ controller: UIViewController) -> Bool {
        var current: UIViewController? = controller
        while let candidate = current {
            if candidate.isBeingDismissed { return true }
            current = candidate.parent
        }
        return false
    }

    /// Whether a sheet not being dismissed is still over `owner`: the screen that went gave way to a
    /// view that isn't one, inside that sheet. `presentedViewController` answers for the parents
    /// too, and a SwiftUI screen asks the controller hosting it.
    private static func isCovered(_ owner: AnyObject?) -> Bool {
        let controller = owner as? UIViewController ?? (owner as? ScreenInstance)?.controller
        guard let presented = controller?.presentedViewController else { return false }
        return !presented.isBeingDismissed
    }

    /// Child view controllers walked under one, at most; past it, it is taken to hold a screen.
    static let maxDescendants = 50

    /// The app's own view controllers that hold no screen.
    static func isScreen(_ controller: UIViewController) -> Bool {
        var budget = maxDescendants
        return isAppsOwn(controller) && !holdsScreen(controller, budget: &budget)
    }

    /// Whether a controller under `controller` is the app's own, or a hosting controller whose
    /// SwiftUI view may name the screen. Apple's others (a player, a web view) are part of it.
    private static func holdsScreen(_ controller: UIViewController, budget: inout Int) -> Bool {
        controller.children.contains { child in
            budget -= 1
            return budget < 0 || isAppsOwn(child) || isHosting(child)
                || holdsScreen(child, budget: &budget)
        }
    }

    private static func isAppsOwn(_ controller: UIViewController) -> Bool {
        if controller is UINavigationController || controller is UITabBarController
            || controller is UIPageViewController || controller is UISplitViewController
            || isHosting(controller)
        {
            return false
        }
        return !isApplesClass(type(of: controller))
    }

    /// SwiftUI's `UIHostingController`, or an app's subclass of it. The name is read first, being
    /// cheaper than the bundle lookup, and the climb stops at `UIViewController`.
    private static func isHosting(_ controller: UIViewController) -> Bool {
        var cls: AnyClass? = type(of: controller)
        while let current = cls, current != UIViewController.self {
            if NSStringFromClass(current).contains("UIHostingController"), isApplesClass(current) {
                return true
            }
            cls = class_getSuperclass(current)
        }
        return false
    }

    /// Apple's frameworks live under /System (or the simulator's copy of it); an app's own classes,
    /// and any library it links, don't.
    static func isApplesClass(_ cls: AnyClass) -> Bool {
        let path = Bundle(for: cls).bundlePath
        return path.hasPrefix("/System/") || path.contains("/System/Library/")
            || path.hasPrefix("/usr/lib/")
    }

    /// The class name without its module or generic arguments: `DetailViewController`.
    static func screenName(of controller: UIViewController) -> String {
        TargetResolver.className(of: controller)
    }

    private func key(for controller: UIViewController, name: String) -> String {
        if let key = objc_getAssociatedObject(controller, &screenKeyKey) as? String { return key }
        let key = nextKey(name)
        objc_setAssociatedObject(controller, &screenKeyKey, key, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return key
    }

    private func nextKey(_ name: String) -> String {
        let next = (counters[name] ?? 0) + 1
        counters[name] = next
        return "\(name)-\(next)"
    }
}

private var screenKeyKey: UInt8 = 0

/// A SwiftUI screen's own token, kept in its view's state.
final class ScreenInstance {
    var key: String?

    /// The ``ScreenMarker`` view behind the screen, the way to the controller hosting it.
    weak var view: UIView?

    /// The view controller hosting the screen, from its marker's responder chain.
    var controller: UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// Puts an empty, untouchable view behind a SwiftUI screen, as ``PrivateMarker`` does, so its
/// instance can reach the view controller hosting it.
struct ScreenMarker: UIViewRepresentable {
    let instance: ScreenInstance

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        instance.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        instance.view = view
    }
}

/// Reports the view it modifies as a screen whenever it appears, and when it goes away.
struct ScreenModifier: ViewModifier {
    let name: String
    let key: String?
    @State private var instance = ScreenInstance()

    func body(content: Content) -> some View {
        content
            .background(ScreenMarker(instance: instance).accessibilityHidden(true))
            .onAppear {
                ScreenTracker.shared.swiftUIScreenAppeared(name: name, key: key, instance: instance)
            }
            .onDisappear { ScreenTracker.shared.swiftUIScreenDisappeared(instance) }
    }
}
