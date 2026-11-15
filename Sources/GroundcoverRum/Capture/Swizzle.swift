import Foundation
import ObjectiveC

/// The one way the SDK replaces a method. Every method it swizzles is already swizzled by someone
/// else (another SDK, for one), so:
/// - Only a method the class implements itself (replacing an inherited one would change every
///   other subclass of its owner), and only when its signature is the one expected: a different
///   one (a future OS, another SDK's override) is skipped, never forced.
/// - The replacement calls the previous implementation (the original, or another SDK's) exactly
///   once, first, so whoever swizzled before still runs and the app's own handling never waits on
///   the SDK. Then it only observes, cheaply: it never changes, delays, swallows or reorders what
///   it sees. The one exception is `resume`, which must give a request its trace headers before it
///   goes out: it does that first, and changes nothing else.
/// - Installed once, from `Groundcover.start`, never from `+load`, so an app that doesn't start the
///   SDK is never touched. Never undone, since whoever swizzled after us calls ours:
///   `GroundcoverRumTesting.reset()` disarms the observer instead.
/// - Each hook has its own switch in ``NativeHooks``, for an app whose own instrumentation clashes.
///
/// What is swizzled: `UIApplication.sendEvent(_:)` for touches (``NativeHooks/touches``),
/// `UIViewController.viewDidAppear(_:)` and `viewDidDisappear(_:)` for screens
/// (``NativeHooks/viewControllers``), and `URLSessionTask`'s `resume` and its private `setState:`
/// for requests (``NativeHooks/urlSession``), the two other network instrumentation hooks too. No
/// gesture recognizer or delegate proxy. A test installs a second swizzler before and after ours
/// and checks every one runs, the original once.
enum Swizzle {
    /// Replaces `selector` on `cls` with `makeBlock(previous)`, an `@convention(block)` closure
    /// taking the receiver and then the method's arguments, and returns true. Returns false, and
    /// changes nothing, when `cls` doesn't implement `selector` itself (replacing an inherited
    /// method would change every other subclass of its owner) or when the method's type encoding,
    /// read without its offsets (`v@:@`), isn't `signature`.
    static func replace(
        _ cls: AnyClass, _ selector: Selector, signature: String, _ makeBlock: (IMP) -> Any
    ) -> Bool {
        guard let method = method(cls, selector, signature: signature) else {
            RumDiagnostics.shared.log(
                "[capture] \(NSStringFromClass(cls)).\(NSStringFromSelector(selector)) "
                    + "isn't the method expected; not hooked")
            return false
        }
        let previous = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(makeBlock(previous)))
        return true
    }

    /// `cls`'s method for `selector` when its type encoding, read without its offsets, is
    /// `signature`: its own only, unless `inherited`. Nil for any other.
    static func method(
        _ cls: AnyClass, _ selector: Selector, signature: String, inherited: Bool = false
    ) -> Method? {
        guard
            let method = inherited
                ? class_getInstanceMethod(cls, selector) : ownMethod(cls, selector),
            let encoding = method_getTypeEncoding(method),
            strippedEncoding(String(cString: encoding)) == signature
        else { return nil }
        return method
    }

    /// `cls`'s own method for `selector`, never one it inherits.
    private static func ownMethod(_ cls: AnyClass, _ selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return nil }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return methods[index]
        }
        return nil
    }

    /// A type encoding without its stack offsets: `v24@0:8@16` reads `v@:@`.
    static func strippedEncoding(_ encoding: String) -> String {
        String(encoding.filter { !$0.isNumber })
    }
}
