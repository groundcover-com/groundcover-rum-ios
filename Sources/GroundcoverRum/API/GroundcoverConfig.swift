import Foundation

// The SDK's configuration surface.
//
// Names mirror the React Native and Flutter SDKs one to one, so their READMEs and the dashboards'
// vocabulary carry over. Only the types are Swift's: a TimeInterval in seconds where React Native
// takes milliseconds, a URLPattern where it takes `string | RegExp`. Every option is optional, and
// nil means the default.

/// What ``Groundcover/start(_:)`` takes.
public struct GroundcoverConfig {
    public var apiKey: String

    /// The ingest host, with or without a scheme; batches go to `{dsn}/json/rum`.
    public var dsn: String

    public var cluster: String
    public var environment: String

    /// The application's identity. Must not be blank.
    public var appId: String

    public var namespace: String?
    public var releaseId: String?
    public var user: RumUser?

    /// Start with this session id instead of a generated or persisted one.
    public var sessionId: String?

    public var options: GroundcoverOptions

    public init(
        apiKey: String,
        dsn: String,
        cluster: String,
        environment: String,
        appId: String,
        namespace: String? = nil,
        releaseId: String? = nil,
        user: RumUser? = nil,
        sessionId: String? = nil,
        options: GroundcoverOptions = GroundcoverOptions()
    ) {
        self.apiKey = apiKey
        self.dsn = dsn
        self.cluster = cluster
        self.environment = environment
        self.appId = appId
        self.namespace = namespace
        self.releaseId = releaseId
        self.user = user
        self.sessionId = sessionId
        self.options = options
    }
}

/// Options for ``GroundcoverConfig``. The ones ``GroundcoverOptionsUpdate`` also carries can change
/// after start; the rest are fixed then.
public struct GroundcoverOptions {
    /// Which signals to capture. Nil or empty means all. Fixed at start.
    public var enabledEvents: [RumEventName]?

    /// The share of sessions to record, from 0 to 1. Defaults to 1. Decided once per session.
    public var sessionSampleRate: Double?

    /// The target longest session, in seconds. Enforced on the next activity, so an idle session
    /// keeps its id past it. Defaults to 4 hours; must be between 1 minute and 8 hours, or the
    /// default applies. Sessions also end after 30 minutes without user input.
    public var sessionMaxDuration: TimeInterval?

    /// Logs what the SDK does, with a `[groundcover]` prefix.
    public var debug: Bool?

    /// Requests network capture skips. The SDK's own requests are always skipped.
    public var excludedUrls: [URLPattern]?

    /// Inspects each event before it is queued; return false to drop it.
    public var beforeSend: BeforeSend?

    /// Changes each event before it is queued, and returns it.
    public var enrichEvent: EnrichEvent?

    public var privacy: PrivacyOptions?
    public var tracing: TracingOptions?
    public var transport: TransportOptions?

    /// The app version on the session envelope, when the bundle's own should not be used. Fixed at
    /// start.
    public var appVersion: String?

    /// The app build on the session envelope, when the bundle's own should not be used. Fixed at
    /// start.
    public var appBuild: String?

    /// Tuning for hangs, frame vitals and time to interactive. Fixed at start.
    public var native: NativeOptions?

    /// The automatic capture hooks, each of which can be turned off. Fixed at start.
    public var hooks: NativeHooks

    public init(
        enabledEvents: [RumEventName]? = nil,
        sessionSampleRate: Double? = nil,
        sessionMaxDuration: TimeInterval? = nil,
        debug: Bool? = nil,
        excludedUrls: [URLPattern]? = nil,
        beforeSend: BeforeSend? = nil,
        enrichEvent: EnrichEvent? = nil,
        privacy: PrivacyOptions? = nil,
        tracing: TracingOptions? = nil,
        transport: TransportOptions? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        native: NativeOptions? = nil,
        hooks: NativeHooks = NativeHooks()
    ) {
        self.enabledEvents = enabledEvents
        self.sessionSampleRate = sessionSampleRate
        self.sessionMaxDuration = sessionMaxDuration
        self.debug = debug
        self.excludedUrls = excludedUrls
        self.beforeSend = beforeSend
        self.enrichEvent = enrichEvent
        self.privacy = privacy
        self.tracing = tracing
        self.transport = transport
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.native = native
        self.hooks = hooks
    }
}

/// The signals ``GroundcoverOptions/enabledEvents`` switches, by the React Native SDK's names.
public enum RumEventName: String, CaseIterable {
    case interaction
    case network
    case logs
    case navigation
    case exceptions
    /// Crashes, reported on the next launch under the session they happened in.
    case crashes
    /// Main-thread stalls the app recovered from.
    case hangs
    /// Slow and frozen frames, and the time they lost, per screen.
    case vitals
    /// App start (cold and hot) and time to interactive.
    case appStart
}

/// The automatic capture hooks. Each is on by default and can be turned off on its own, for an app
/// whose own instrumentation clashes with it; what it captured can then be sent through the API.
public struct NativeHooks {
    /// Screens from `viewDidAppear(_:)` on the app's own view controllers, each named by its class,
    /// and from `viewDidDisappear(_:)` the one under a dismissed sheet, current again.
    /// A controller holding one of the app's own or a hosting controller is a container, never a
    /// screen, and so are Apple's own (navigation, tab bar, hosting controllers, the app's
    /// subclasses of a hosting controller included): a SwiftUI screen names itself with
    /// `groundcoverScreen(_:key:)`. Apple's other controllers inside a screen (a player, a web
    /// view) leave it a screen.
    public var viewControllers: Bool

    /// Taps and gestures, from the touches every window receives.
    public var touches: Bool

    /// One input event when editing a text field or text view ends, or when a tap lands outside it
    /// while it is still being edited. Never the text.
    public var textFields: Bool

    /// Every request URLSession's classic loader sends, the default loader of every session, from
    /// `URLSessionTask`'s `resume` and its completion: trace headers on the way out unless the
    /// request carries its own traceparent, a network event when it ends, without its response
    /// body. A session that sets `usesClassicLoadingMode = false` isn't seen: record its requests
    /// through the API.
    public var urlSession: Bool

    public init(
        viewControllers: Bool = true, touches: Bool = true, textFields: Bool = true,
        urlSession: Bool = true
    ) {
        self.viewControllers = viewControllers
        self.touches = touches
        self.textFields = textFields
        self.urlSession = urlSession
    }
}

/// A URL that ``GroundcoverOptions/excludedUrls`` matches.
public enum URLPattern: ExpressibleByStringLiteral {
    /// A string with `*` or `?` is a glob matched anywhere in the URL, where `*` is any run of
    /// characters and `?` any one character. Any other string must equal the whole URL.
    case string(String)

    /// A regular expression, matched anywhere in the URL.
    case regex(NSRegularExpression)

    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

/// The master switch for data masking.
public enum PrivacyLevel: String {
    /// Masks sensitive data only: sensitive-key matches, views marked private, and network, log and
    /// error payloads. The default.
    case maskSensitive = "mask-sensitive"

    /// Also masks the label, hint and value text of every tap and input.
    case maskAll = "mask-all"

    /// Opts out of masking, except credential headers.
    case allow
}

/// The event surface a ``RedactField`` belongs to.
public enum RedactKind: String {
    case requestBody = "request-body"
    case responseBody = "response-body"
    case query
    case header
    case log
    case error
}

/// One leaf value the redaction walk visits, as a ``Redactor`` sees it.
public struct RedactField {
    /// The leaf's own key; empty for a whole-string field (a log or error message).
    public var key: String

    /// The leaf value: a string, number, Bool or nil, never a dictionary or array.
    public var value: Any?

    /// The full key path to the leaf; empty for a whole-string field.
    public var path: [String]

    public var kind: RedactKind

    /// Whether the built-in patterns or `sensitiveKeys` would redact it.
    public var sensitive: Bool

    public init(key: String, value: Any?, path: [String], kind: RedactKind, sensitive: Bool) {
        self.key = key
        self.value = value
        self.path = path
        self.kind = kind
        self.sensitive = sensitive
    }
}

/// A per-leaf redaction hook. Return a replacement string, number or Bool, or nil to keep the
/// SDK's default (`[REDACTED]` when the field is sensitive, the value otherwise), so a hook that
/// cares about one field can't switch masking off elsewhere. Called off the main thread. A hook
/// that throws gets the default for that field.
public typealias Redactor = @Sendable (RedactField) throws -> Any?

/// Inspects an event before it is queued; return false to drop it. Called off the main thread. A
/// hook that throws drops the event.
public typealias BeforeSend = @Sendable (RumEvent) throws -> Bool

/// Changes an event before it is queued, and returns it. Called off the main thread. A hook that
/// throws drops the event.
public typealias EnrichEvent = @Sendable (RumEvent) throws -> RumEvent

/// Data masking for every captured surface. On by default, at ``PrivacyLevel/maskSensitive``.
public struct PrivacyOptions {
    public var level: PrivacyLevel?

    /// Redact network request and response bodies. On unless the level is `allow`.
    public var maskNetworkBodies: Bool?

    /// Redact URL query parameters. On unless the level is `allow`.
    public var maskNetworkQueryParams: Bool?

    /// Redact log messages and attributes. On unless the level is `allow`.
    public var maskLogs: Bool?

    /// Redact error messages and metadata; stack frames are sent as they are. On unless the level
    /// is `allow`.
    public var maskErrors: Bool?

    /// Extra case-insensitive key substrings to treat as sensitive, added to the built-in patterns.
    public var sensitiveKeys: [String]?

    public var redact: Redactor?

    /// Mask tap labels under any level. Always on under `maskAll`; the role and component path
    /// stay, being structural.
    public var maskInteractionLabels: Bool?

    public init(
        level: PrivacyLevel? = nil,
        maskNetworkBodies: Bool? = nil,
        maskNetworkQueryParams: Bool? = nil,
        maskLogs: Bool? = nil,
        maskErrors: Bool? = nil,
        sensitiveKeys: [String]? = nil,
        redact: Redactor? = nil,
        maskInteractionLabels: Bool? = nil
    ) {
        self.level = level
        self.maskNetworkBodies = maskNetworkBodies
        self.maskNetworkQueryParams = maskNetworkQueryParams
        self.maskLogs = maskLogs
        self.maskErrors = maskErrors
        self.sensitiveKeys = sensitiveKeys
        self.redact = redact
        self.maskInteractionLabels = maskInteractionLabels
    }
}

/// The `origin` tag stamped on injected trace headers.
public struct TracingOrigin {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Distributed-tracing header propagation for outgoing requests.
public struct TracingOptions {
    /// Request URLs that get a `traceparent` header: whole-URL matches in which only `*` is a
    /// wildcard.
    public var propagationUrls: [String]?

    /// Header names that carry the W3C trace context on traced requests. When set, they replace
    /// `traceparent`: list it too to keep it.
    public var propagationHeaders: [String]?

    /// A header that also carries the trace id.
    public var traceIdHeaderName: String?

    /// A header that also carries the span id.
    public var spanIdHeaderName: String?

    public var origin: TracingOrigin?

    public init(
        propagationUrls: [String]? = nil,
        propagationHeaders: [String]? = nil,
        traceIdHeaderName: String? = nil,
        spanIdHeaderName: String? = nil,
        origin: TracingOrigin? = nil
    ) {
        self.propagationUrls = propagationUrls
        self.propagationHeaders = propagationHeaders
        self.traceIdHeaderName = traceIdHeaderName
        self.spanIdHeaderName = spanIdHeaderName
        self.origin = origin
    }
}

/// Batching and delivery.
public struct TransportOptions {
    /// Events buffered before a batch is sent. Defaults to 10; 0 sends every event on its own.
    public var batchSize: Int?

    /// Longest a batch waits before it is sent anyway, in seconds. Defaults to 10.
    public var batchTimeout: TimeInterval?

    /// Gzip outgoing batches. Defaults to true.
    public var compression: Bool?

    public init(batchSize: Int? = nil, batchTimeout: TimeInterval? = nil, compression: Bool? = nil)
    {
        self.batchSize = batchSize
        self.batchTimeout = batchTimeout
        self.compression = compression
    }
}

/// Tuning for hangs, frame vitals and time to interactive. Tuning only:
/// ``GroundcoverOptions/enabledEvents`` is the one way to turn a signal off.
public struct NativeOptions {
    /// How long the main thread must be blocked before a hang is reported, in seconds. Defaults to
    /// 2; a value outside 0.25 to 60 falls back to it.
    public var hangThreshold: TimeInterval?

    /// Longest a frame-vitals segment may run before it is closed anyway, in seconds. Defaults to
    /// 60; a value outside 1 to 300 falls back to it. Segments normally end on a screen change or
    /// on backgrounding, so this is a safety valve, not a cadence.
    public var vitalsMaxSegment: TimeInterval?

    /// Which moment counts as interactive. Defaults to ``TtiMode/auto``.
    public var tti: TtiMode?

    public init(
        hangThreshold: TimeInterval? = nil,
        vitalsMaxSegment: TimeInterval? = nil,
        tti: TtiMode? = nil
    ) {
        self.hangThreshold = hangThreshold
        self.vitalsMaxSegment = vitalsMaxSegment
        self.tti = tti
    }
}

/// Which moment counts as interactive for time to interactive.
public enum TtiMode: String {
    /// The first screen landing. A floor, not a promise: it comes before that screen's data loads.
    case auto

    /// When the app calls ``Groundcover/markAppInteractive()``: the honest measure, called once
    /// the first screen is genuinely usable.
    case manual
}

/// A user identity, stamped on every batch once set.
public struct RumUser {
    public var id: String?
    public var email: String?
    public var name: String?
    public var role: String?
    public var organization: String?
    public var properties: [String: Any]?

    public init(
        id: String? = nil,
        email: String? = nil,
        name: String? = nil,
        role: String? = nil,
        organization: String? = nil,
        properties: [String: Any]? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.role = role
        self.organization = organization
        self.properties = properties
    }
}

/// What ``Groundcover/updateConfig(_:)`` takes: ``GroundcoverConfig`` without what is fixed at
/// start. Nil fields stay as they are.
public struct GroundcoverConfigUpdate {
    public var apiKey: String?
    public var dsn: String?
    public var cluster: String?
    public var environment: String?
    public var namespace: String?
    public var releaseId: String?
    public var user: UserUpdate?
    public var options: GroundcoverOptionsUpdate?

    public init(
        apiKey: String? = nil,
        dsn: String? = nil,
        cluster: String? = nil,
        environment: String? = nil,
        namespace: String? = nil,
        releaseId: String? = nil,
        user: UserUpdate? = nil,
        options: GroundcoverOptionsUpdate? = nil
    ) {
        self.apiKey = apiKey
        self.dsn = dsn
        self.cluster = cluster
        self.environment = environment
        self.namespace = namespace
        self.releaseId = releaseId
        self.user = user
        self.options = options
    }
}

/// A change to the identity in ``GroundcoverConfigUpdate``.
public enum UserUpdate {
    /// Merges into the identity: the fields it gives replace the current ones, and the rest stay.
    case set(RumUser)

    /// Removes it, as at a logout, so the next user's events don't carry it.
    case clear
}

/// The options ``Groundcover/updateConfig(_:)`` can change. Nil fields stay as they are.
public struct GroundcoverOptionsUpdate {
    public var sessionMaxDuration: TimeInterval?
    public var debug: Bool?
    public var excludedUrls: [URLPattern]?
    public var beforeSend: BeforeSend?
    public var enrichEvent: EnrichEvent?
    public var privacy: PrivacyOptions?
    public var tracing: TracingOptions?
    public var transport: TransportOptions?

    public init(
        sessionMaxDuration: TimeInterval? = nil,
        debug: Bool? = nil,
        excludedUrls: [URLPattern]? = nil,
        beforeSend: BeforeSend? = nil,
        enrichEvent: EnrichEvent? = nil,
        privacy: PrivacyOptions? = nil,
        tracing: TracingOptions? = nil,
        transport: TransportOptions? = nil
    ) {
        self.sessionMaxDuration = sessionMaxDuration
        self.debug = debug
        self.excludedUrls = excludedUrls
        self.beforeSend = beforeSend
        self.enrichEvent = enrichEvent
        self.privacy = privacy
        self.tracing = tracing
        self.transport = transport
    }
}
