import Foundation

/// The SDK's entry point.
///
/// ```swift
/// func application(
///     _ application: UIApplication,
///     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
/// ) -> Bool {
///     do {
///         try Groundcover.start(GroundcoverConfig(
///             apiKey: "your-rum-ingestion-key",
///             dsn: "https://example.platform.grcv.io",
///             cluster: "your-cluster",
///             environment: "production",
///             appId: "my-ios-app"))
///     } catch {
///         // The SDK couldn't start, and the app runs unmonitored.
///         print("groundcover: \(error)")
///     }
///     return true
/// }
/// ```
///
/// Calls made before ``start(_:)`` are dropped, with a warning when `debug` is on. No call throws
/// into the app except `start`, and every call but `start` returns at once: the work happens off
/// the main thread.
public enum Groundcover {
    /// Starts the SDK. Call it once, early in `application(_:didFinishLaunchingWithOptions:)`.
    /// Throws ``GroundcoverInitError`` when the configuration is invalid: a blank `appId`. A later
    /// call does nothing. It returns once the session is ready, so ``sessionId`` holds it at once;
    /// that takes a few milliseconds, and never more than a second.
    public static func start(_ config: GroundcoverConfig) throws {
        let runtime = RumRuntime.shared
        guard try runtime.start(config), !runtime.isUnsampled else { return }
        Instrumentation.shared.arm(config, runtime: runtime)
    }

    /// Stamps `user` on every batch from now on, merged into any identity set before.
    public static func identifyUser(_ user: RumUser) {
        RumRuntime.shared.dispatch("identifyUser") { $0.identifyUser(user) }
    }

    /// Changes the configuration after ``start(_:)``. What is fixed at start isn't part of
    /// ``GroundcoverConfigUpdate``.
    public static func updateConfig(_ update: GroundcoverConfigUpdate) {
        RumRuntime.shared.dispatch("updateConfig") { $0.updateConfig(update) }
    }

    /// Sends a custom event named `name`. Its `attributes` are sent as given: custom events are not
    /// redacted, so scrub them in `enrichEvent` if they can carry personal data.
    public static func sendCustomEvent(_ name: String, _ attributes: [String: Any] = [:]) {
        let capture = CustomEventCapture(
            name: name, attributes: attributes, timestampNs: callTimeNs())
        RumRuntime.shared.dispatch("sendCustomEvent") { $0.submit(.custom(capture)) }
    }

    /// Reports a handled `error`, placed by this call's stack, with optional `metadata`.
    @inline(never)
    public static func captureError(_ error: Error, metadata: [String: Any]? = nil) {
        // The stack opens with this call's own frame, left out by place: a stripped app has no
        // symbol to tell it by.
        reportError(error, metadata, Array(Thread.callStackReturnAddresses.dropFirst()))
    }

    /// Reports a handled `error` placed by `stack`, the return addresses from its caller's frame
    /// on. The capture point reads them, ``captureError(_:metadata:)`` or the Objective-C
    /// facade's, and leaves its own frames out by place.
    package static func reportError(
        _ error: Error, _ metadata: [String: Any]?, _ stack: [NSNumber]
    ) {
        let type = errorTypeName(error)
        let message = errorMessage(error)
        let timestampNs = callTimeNs()
        // Only the addresses are read on the caller's thread. Resolving them (a dladdr per frame)
        // waits for the core queue, and doesn't happen at all for a call that is dropped there.
        RumRuntime.shared.dispatch("captureError") {
            $0.submit(
                .error(
                    ErrorCapture(
                        type: type, message: message, frames: CallStack.frames(stack),
                        handled: true, metadata: metadata, timestampNs: timestampNs)))
        }
    }

    /// Sends log events.
    public static let logger = RumLogger()

    /// The current session id, or `""` before the SDK has started or when this session isn't
    /// sampled.
    public static var sessionId: String { RumRuntime.shared.sessionId }

    /// Starts a new session, with `id` or a generated one. Whatever the old session buffered is
    /// sent under it first, and this returns once it has been handed over.
    public static func setSessionId(_ id: String? = nil) async {
        await withCheckedContinuation { continuation in
            RumRuntime.shared.setSessionId(id) { continuation.resume() }
        }
    }

    /// Starts a manual navigation to `screen`, with an optional `key` telling two visits to it
    /// apart. It is stamped on events from now on; a blank `screen` is never reported. `metadata`
    /// travels with the navigation.
    public static func startNavigation(
        _ screen: String,
        key: String = "",
        metadata: [String: Any]? = nil
    ) {
        let capture = NavigationCapture.start(screen: screen, key: key, metadata: metadata)
        RumRuntime.shared.dispatch("startNavigation") { $0.submit(.navigation(capture)) }
    }

    /// Ends the manual navigation ``startNavigation(_:key:metadata:)`` began and reports it, with
    /// both calls' `metadata` merged.
    public static func endNavigation(_ metadata: [String: Any]? = nil) {
        RumRuntime.shared.dispatch("endNavigation") {
            $0.submit(.navigation(.end(metadata: metadata)))
        }
    }

    /// Stops automatic screen tracking. Manual navigations still report.
    public static func stopNavigationTracking() {
        Instrumentation.shared.stopNavigationTracking()
    }

    /// Marks the moment the app became usable, for time to interactive when ``NativeOptions/tti``
    /// is ``TtiMode/manual``. Call it once, when the first screen is genuinely ready. Only the first
    /// call counts, and it counts before ``start(_:)`` too.
    public static func markAppInteractive() {
        let runtime = RumRuntime.shared
        guard InteractiveMarks.shared.markManual(nowMs: runtime.nowMs), runtime.isStarted else {
            return
        }
        runtime.dispatch("markAppInteractive") { $0.interactiveMarked() }
    }
}

/// Log events, one method per level. `attributes` travel with the message.
public struct RumLogger: Sendable {
    public func log(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .log, attributes)
    }

    public func info(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .info, attributes)
    }

    public func warn(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .warn, attributes)
    }

    public func error(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .error, attributes)
    }

    public func debug(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .debug, attributes)
    }

    public func trace(_ message: String, _ attributes: [String: Any]? = nil) {
        send(message, .trace, attributes)
    }

    private func send(_ message: String, _ level: LogLevel, _ attributes: [String: Any]?) {
        let capture = LogCapture(
            message: message, level: level, attributes: attributes, timestampNs: callTimeNs())
        RumRuntime.shared.dispatch("logger.\(level.rawValue)") { $0.submit(.log(capture)) }
    }
}

/// When the app made the call, read on its own thread: the core queue may run it later.
private func callTimeNs() -> Int64 {
    msToNs(RumRuntime.shared.nowMs)
}

/// The error's type, the grouping key with its message: `URLError`, `DecodingError`. Apple's
/// frameworks hand over an NSError underneath, so a bridged one is named by its Swift type and
/// any other NSError by its domain.
func errorTypeName(_ error: Error) -> String {
    switch error {
    case is URLError: return "URLError"
    case is CocoaError: return "CocoaError"
    case is POSIXError: return "POSIXError"
    case is MachError: return "MachError"
    default: break
    }
    let type = type(of: error)
    if type is NSError.Type { return (error as NSError).domain }
    return String(describing: type)
}

/// What the error says: its LocalizedError description, an NSError's own, or how Swift prints it.
private func errorMessage(_ error: Error) -> String {
    if let description = (error as? LocalizedError)?.errorDescription { return description }
    if type(of: error) is NSError.Type { return (error as NSError).localizedDescription }
    return String(describing: error)
}

/// Thrown by ``Groundcover/start(_:)`` when the SDK can't start. Its `localizedDescription`,
/// an Objective-C caller's `NSError` description included, is the reason.
public struct GroundcoverInitError: LocalizedError, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { "GroundcoverInitError: \(message)" }
}
