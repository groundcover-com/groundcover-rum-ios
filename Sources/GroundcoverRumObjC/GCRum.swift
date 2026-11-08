import Foundation
import GroundcoverRum

// The Objective-C facade: @objc classes over the Swift API, for Objective-C and Objective-C++
// hosts. Same names and defaults as the Swift API; optional numbers are NSNumber, nil meaning the
// default. `UIView.groundcoverPrivate` needs no facade: it is @objc in GroundcoverRum itself.
//
//   GroundcoverConfig *config = [[GroundcoverConfig alloc] initWithApiKey:@"…" dsn:@"…"
//       cluster:@"…" environment:@"production" appId:@"my-ios-app"];
//   NSError *error = nil;
//   if (![Groundcover startWithConfig:config error:&error]) { NSLog(@"groundcover: %@", error); }
//
// Objective-C sees the Swift API's names: Groundcover, GroundcoverConfig, GroundcoverUser… The
// Swift names keep a GCRum prefix, since this module imports the Swift API's own Groundcover and
// GroundcoverConfig. Neither is @objc, so nothing clashes in the Objective-C runtime.

/// The SDK's entry point, as ``GroundcoverRum/Groundcover``.
@objc(Groundcover)
public final class GCRum: NSObject {
    private override init() {}

    /// Starts the SDK. Fails, with the reason in `error`, when the configuration is invalid: a
    /// blank `appId`, an `enabledEvents` name the SDK doesn't know, or an `excludedUrls` entry
    /// that is neither a string nor a regular expression.
    @objc(startWithConfig:error:)
    public static func start(config: GCRumConfig) throws {
        try Groundcover.start(config.swiftConfig())
    }

    @objc public static func identifyUser(_ user: GCRumUser) {
        Groundcover.identifyUser(user.swiftUser)
    }

    /// Removes the identity, as at a logout.
    @objc public static func clearUser() {
        Groundcover.updateConfig(GroundcoverConfigUpdate(user: .clear))
    }

    @objc(sendCustomEvent:attributes:)
    public static func sendCustomEvent(_ name: String, attributes: [String: Any]?) {
        Groundcover.sendCustomEvent(name, attributes ?? [:])
    }

    @objc(captureError:metadata:)
    @inline(never)
    public static func captureError(_ error: NSError, metadata: [String: Any]?) {
        // The capture point, never inlined: the stack opens with its own frame, then the @objc
        // thunk Objective-C calls it through, in a debug build and an optimized one alike. Both
        // are left out by place: a stripped app has no symbol to tell them by.
        Groundcover.reportError(
            error, metadata, Array(Thread.callStackReturnAddresses.dropFirst(2)))
    }

    @objc(logWithLevel:message:attributes:)
    public static func log(level: GCRumLogLevel, message: String, attributes: [String: Any]?) {
        let logger = Groundcover.logger
        switch level {
        case .log: logger.log(message, attributes)
        case .info: logger.info(message, attributes)
        case .warn: logger.warn(message, attributes)
        case .error: logger.error(message, attributes)
        case .debug: logger.debug(message, attributes)
        case .trace: logger.trace(message, attributes)
        }
    }

    @objc public static var sessionId: String { Groundcover.sessionId }

    @objc(setSessionId:completion:)
    public static func setSessionId(_ id: String?, completion: (() -> Void)?) {
        Task {
            await Groundcover.setSessionId(id)
            completion?()
        }
    }

    @objc(startNavigation:key:metadata:)
    public static func startNavigation(_ screen: String, key: String?, metadata: [String: Any]?) {
        Groundcover.startNavigation(screen, key: key ?? "", metadata: metadata)
    }

    @objc(endNavigation:)
    public static func endNavigation(_ metadata: [String: Any]?) {
        Groundcover.endNavigation(metadata)
    }

    @objc public static func stopNavigationTracking() {
        Groundcover.stopNavigationTracking()
    }

    @objc public static func markAppInteractive() {
        Groundcover.markAppInteractive()
    }
}

@objc(GroundcoverLogLevel)
public enum GCRumLogLevel: Int {
    case log
    case info
    case warn
    case error
    case debug
    case trace
}

/// ``GroundcoverRum/GroundcoverConfig``, with its options flattened in.
@objc(GroundcoverConfig)
public final class GCRumConfig: NSObject {
    @objc public var apiKey: String
    @objc public var dsn: String
    @objc public var cluster: String
    @objc public var environment: String
    @objc public var appId: String
    /// The config's `namespace`. Named apart because `namespace` is a C++ keyword, which an
    /// Objective-C++ host couldn't write.
    @objc public var namespaceName: String?
    @objc public var releaseId: String?
    @objc public var user: GCRumUser?
    @objc public var sessionId: String?

    /// `RumEventName` raw values: `@"interaction"`, `@"crashes"`, `@"appStart"`… Nil or empty
    /// means all. An unknown name fails the start rather than being dropped, since a list left
    /// empty would mean all.
    @objc public var enabledEvents: [String]?
    /// A double from 0 to 1.
    @objc public var sessionSampleRate: NSNumber?
    /// Seconds, as a double.
    @objc public var sessionMaxDuration: NSNumber?
    @objc public var debug: NSNumber?
    /// Each a string as ``GroundcoverRum/URLPattern/string(_:)`` or an NSRegularExpression;
    /// anything else fails the start.
    @objc public var excludedUrls: [Any]?
    @objc public var privacyLevel: GCRumPrivacyLevel = .default
    /// Extra keys whose values are redacted, matched as case-insensitive substrings, on top of the
    /// built-in list.
    @objc public var sensitiveKeys: [String]?
    /// A boolean: mask tap labels under any privacy level.
    @objc public var maskInteractionLabels: NSNumber?
    /// Return `NO` to drop the event. Runs on the SDK's queue, not the main thread, and must not
    /// raise: an Objective-C exception can't be caught on its way back through Swift.
    @objc public var beforeSend: ((GCRumEvent) -> Bool)?
    /// Changes the event in place, through its `attributes`, after `beforeSend` keeps it. Custom
    /// events are never redacted, so this is where their contents are cleaned. Same rules as
    /// `beforeSend`.
    @objc public var enrichEvent: ((GCRumEvent) -> Void)?
    @objc public var propagationUrls: [String]?
    @objc public var batchSize: NSNumber?
    /// Seconds, as a double.
    @objc public var batchTimeout: NSNumber?
    @objc public var compression: NSNumber?
    @objc public var appVersion: String?
    @objc public var appBuild: String?
    /// Seconds, as a double.
    @objc public var hangThreshold: NSNumber?
    /// Seconds, as a double.
    @objc public var vitalsMaxSegment: NSNumber?
    @objc public var manualTimeToInteractive: Bool = false
    @objc public var viewControllerHook: Bool = true
    @objc public var touchesHook: Bool = true
    @objc public var textFieldsHook: Bool = true
    @objc public var urlSessionHook: Bool = true

    @objc public init(
        apiKey: String,
        dsn: String,
        cluster: String,
        environment: String,
        appId: String
    ) {
        self.apiKey = apiKey
        self.dsn = dsn
        self.cluster = cluster
        self.environment = environment
        self.appId = appId
    }

    /// The Swift config, or the reason there is none. Fails closed: a value the facade can't map
    /// stops the start, where dropping it would capture what the host asked to exclude.
    func swiftConfig() throws -> GroundcoverConfig {
        try GroundcoverConfig(
            apiKey: apiKey,
            dsn: dsn,
            cluster: cluster,
            environment: environment,
            appId: appId,
            namespace: namespaceName,
            releaseId: releaseId,
            user: user?.swiftUser,
            sessionId: sessionId,
            options: GroundcoverOptions(
                enabledEvents: enabledEvents.map(Self.eventNames),
                sessionSampleRate: sessionSampleRate?.doubleValue,
                sessionMaxDuration: sessionMaxDuration?.doubleValue,
                debug: debug?.boolValue,
                excludedUrls: excludedUrls?.map(Self.urlPattern),
                beforeSend: beforeSend.map { hook in { event in hook(GCRumEvent(event)) } },
                enrichEvent: enrichEvent.map { hook in
                    { event in
                        hook(GCRumEvent(event))
                        return event
                    }
                },
                privacy: privacyOptions(),
                tracing: propagationUrls.map { TracingOptions(propagationUrls: $0) },
                transport: TransportOptions(
                    batchSize: batchSize?.intValue,
                    batchTimeout: batchTimeout?.doubleValue,
                    compression: compression?.boolValue),
                appVersion: appVersion,
                appBuild: appBuild,
                native: NativeOptions(
                    hangThreshold: hangThreshold?.doubleValue,
                    vitalsMaxSegment: vitalsMaxSegment?.doubleValue,
                    tti: manualTimeToInteractive ? .manual : nil),
                hooks: NativeHooks(
                    viewControllers: viewControllerHook,
                    touches: touchesHook,
                    textFields: textFieldsHook,
                    urlSession: urlSessionHook)))
    }

    /// Nil when nothing about privacy was set, so the Swift defaults apply untouched.
    private func privacyOptions() -> PrivacyOptions? {
        let level = privacyLevel.swiftLevel
        guard level != nil || sensitiveKeys != nil || maskInteractionLabels != nil else {
            return nil
        }
        return PrivacyOptions(
            level: level, sensitiveKeys: sensitiveKeys,
            maskInteractionLabels: maskInteractionLabels?.boolValue)
    }

    private static func eventNames(_ names: [String]) throws -> [RumEventName] {
        let unknown = names.filter { RumEventName(rawValue: $0) == nil }
        if !unknown.isEmpty {
            let known = RumEventName.allCases.map(\.rawValue).joined(separator: ", ")
            throw GroundcoverInitError(
                "enabledEvents has unknown names: \(unknown.joined(separator: ", ")) "
                    + "(known: \(known))")
        }
        return names.compactMap(RumEventName.init(rawValue:))
    }

    private static func urlPattern(_ value: Any) throws -> URLPattern {
        switch value {
        case let string as String: return .string(string)
        case let regex as NSRegularExpression: return .regex(regex)
        default:
            throw GroundcoverInitError(
                "excludedUrls takes NSString and NSRegularExpression entries, not \(type(of: value))"
            )
        }
    }
}

/// ``GroundcoverRum/RumEvent``, as an Objective-C `beforeSend` or `enrichEvent` sees it. A hook
/// changes `attributes`; the rest is read-only here.
@objc(GroundcoverEvent)
public final class GCRumEvent: NSObject {
    private let event: RumEvent

    init(_ event: RumEvent) {
        self.event = event
    }

    /// `interaction`, `network`, `log`, `navigation`, `custom`, `exception` or `performance`.
    @objc public var type: String { event.type }
    @objc public var eventId: String { event.id }
    /// Nanoseconds since the epoch; nil on a network event, which has a start and an end instead.
    @objc public var timestamp: NSNumber? { event.timestamp.map { NSNumber(value: $0) } }
    /// Dot-flattened, as in Swift: a tap's label is `@"interaction_target.label"`.
    @objc public var attributes: [String: Any] {
        get { event.attributes }
        set { event.attributes = newValue }
    }
}

@objc(GroundcoverPrivacyLevel)
public enum GCRumPrivacyLevel: Int {
    /// The SDK's default, `maskSensitive`.
    case `default`
    case maskSensitive
    case maskAll
    case allow

    var swiftLevel: PrivacyLevel? {
        switch self {
        case .default: return nil
        case .maskSensitive: return .maskSensitive
        case .maskAll: return .maskAll
        case .allow: return .allow
        }
    }
}

/// ``GroundcoverRum/RumUser``.
@objc(GroundcoverUser)
public final class GCRumUser: NSObject {
    @objc public var id: String?
    @objc public var email: String?
    @objc public var name: String?
    @objc public var role: String?
    @objc public var organization: String?
    @objc public var properties: [String: Any]?

    @objc public init(id: String?) {
        self.id = id
    }

    var swiftUser: RumUser {
        RumUser(
            id: id, email: email, name: name, role: role, organization: organization,
            properties: properties)
    }
}

/// ``GroundcoverRum/GroundcoverRumTesting``: hooks for tests and end-to-end harnesses. Not for
/// production code.
@objc(GroundcoverTesting)
public final class GCRumTesting: NSObject {
    private override init() {}

    @objc public static func backdateLastActivity(by seconds: TimeInterval) {
        GroundcoverRumTesting.backdateLastActivity(by: seconds)
    }

    @objc public static func backdateSessionStart(by seconds: TimeInterval) {
        GroundcoverRumTesting.backdateSessionStart(by: seconds)
    }

    @objc public static func forgetSession() {
        GroundcoverRumTesting.forgetSession()
    }

    @objc public static func triggerTestCrash() {
        GroundcoverRumTesting.triggerTestCrash()
    }

    @objc public static func blockMainThread(for seconds: TimeInterval) {
        GroundcoverRumTesting.blockMainThread(for: seconds)
    }

    @objc public static func reset() {
        GroundcoverRumTesting.reset()
    }
}
