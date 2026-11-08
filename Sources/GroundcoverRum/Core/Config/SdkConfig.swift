import Foundation

// The configuration the pipeline runs on: which groups merge one level deep on an update, how
// sessionMaxDuration is validated, how the identity merges or clears, and which fields an update
// may change. An out-of-range sessionMaxDuration in an update keeps the current cap.

/// The options with every default applied, as the pipeline reads them.
struct ResolvedOptions {
    /// Empty means every signal. Fixed at start, when the capture hooks are installed.
    var enabledEvents: [RumEventName]

    /// Fixed at start, when the sampling verdict is drawn.
    var sessionSampleRate: Double

    var sessionMaxDurationMs: Int64
    var debug: Bool
    var excludedUrls: [URLPattern]
    var beforeSend: BeforeSend?
    var enrichEvent: EnrichEvent?

    /// As provided, merged across updates. ``resolvePrivacy(_:)`` applies the defaults, since it
    /// needs to tell an explicit level from an omitted one.
    var privacy: PrivacyOptions

    var tracing: ResolvedTracing

    /// As provided, merged across updates. The events pool validates the batch size and timeout
    /// where it uses them.
    var transport: TransportOptions

    // Fixed at start.
    var appVersion: String?
    var appBuild: String?
    var native: NativeOptions?
    var hooks: NativeHooks

    func isEnabled(_ name: RumEventName) -> Bool {
        isEventEnabled(enabledEvents, name)
    }
}

/// Whether `enabled`, an `enabledEvents` list, turns on `name`: an empty or absent list turns on
/// everything.
func isEventEnabled(_ enabled: [RumEventName]?, _ name: RumEventName) -> Bool {
    guard let enabled, !enabled.isEmpty else { return true }
    return enabled.contains(name)
}

/// Tracing options with their defaults applied.
struct ResolvedTracing {
    var propagationUrls: [String] = []
    var propagationHeaders: [String] = []
    var traceIdHeaderName = ""
    var spanIdHeaderName = ""
    var origin = TracingOrigin(name: "", value: "")

    /// The headers the traceparent goes in: `propagationHeaders`, else `traceparent`.
    var traceparentHeaders: [String] {
        propagationHeaders.isEmpty ? ["traceparent"] : propagationHeaders
    }

    func merging(_ update: TracingOptions?) -> ResolvedTracing {
        guard let update else { return self }
        return ResolvedTracing(
            propagationUrls: update.propagationUrls ?? propagationUrls,
            propagationHeaders: update.propagationHeaders ?? propagationHeaders,
            traceIdHeaderName: update.traceIdHeaderName ?? traceIdHeaderName,
            spanIdHeaderName: update.spanIdHeaderName ?? spanIdHeaderName,
            origin: update.origin ?? origin)
    }
}

/// The configuration the pipeline runs on: the start config, with defaults applied and updates
/// merged in.
final class SdkConfig {
    private(set) var dsn: String
    let appId: String
    private(set) var cluster: String
    private(set) var apiKey: String
    private(set) var environment: String
    private(set) var namespace: String
    private(set) var releaseId: String?
    private(set) var user: RumUser?
    private(set) var options: ResolvedOptions

    init(_ input: GroundcoverConfig) {
        dsn = input.dsn
        appId = input.appId
        cluster = input.cluster
        apiKey = input.apiKey
        environment = input.environment
        namespace = input.namespace ?? ""
        releaseId = input.releaseId
        user = input.user.map { mergeUser(nil, $0) }

        let options = input.options
        self.options = ResolvedOptions(
            enabledEvents: options.enabledEvents ?? [],
            sessionSampleRate: options.sessionSampleRate ?? defaultSessionSampleRate,
            sessionMaxDurationMs: normalizeSessionMaxDuration(
                options.sessionMaxDuration, current: defaultSessionMaxDurationMs),
            debug: options.debug ?? false,
            excludedUrls: options.excludedUrls ?? [],
            beforeSend: options.beforeSend,
            enrichEvent: options.enrichEvent,
            privacy: options.privacy ?? PrivacyOptions(),
            tracing: ResolvedTracing().merging(options.tracing),
            transport: options.transport ?? TransportOptions(),
            appVersion: options.appVersion,
            appBuild: options.appBuild,
            native: options.native,
            hooks: options.hooks)
    }

    /// The ingest base URL: the DSN, with `https://` when it names no scheme.
    var endpoint: String { dsn.hasPrefix("http") ? dsn : "https://\(dsn)" }

    func update(_ update: GroundcoverConfigUpdate) {
        if let options = update.options {
            self.options = merge(self.options, options)
        }
        switch update.user {
        case .set(let user): self.user = mergeUser(self.user, user)
        case .clear: user = nil
        case nil: break
        }
        if let dsn = present(update.dsn) { self.dsn = dsn }
        if let apiKey = present(update.apiKey) { self.apiKey = apiKey }
        if let cluster = present(update.cluster) { self.cluster = cluster }
        if let environment = present(update.environment) { self.environment = environment }
        if let namespace = present(update.namespace) { self.namespace = namespace }
        if let releaseId = present(update.releaseId) { self.releaseId = releaseId }
    }
}

private func present(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

/// `seconds` as milliseconds when within 1 minute to 8 hours, else `current`: the default at
/// start, and the cap the session already runs on in an update, which the app chose and a bad
/// update shouldn't undo.
private func normalizeSessionMaxDuration(_ seconds: TimeInterval?, current: Int64) -> Int64 {
    guard let seconds else { return current }
    let ms = seconds * 1000
    guard ms >= Double(minSessionMaxDurationMs), ms <= Double(maxSessionMaxDurationMs) else {
        safeWarn(
            "[groundcover] sessionMaxDuration must be between \(minSessionMaxDurationMs) ms "
                + "(1 minute) and \(maxSessionMaxDurationMs) ms (8 hours); using "
                + "\(current / 60_000) minutes")
        return current
    }
    return Int64(ms.rounded())
}

/// `base` with `update`'s non-nil options applied. What start fixes is `base`'s: the capture hooks
/// are installed then and never again, and the sampling verdict is drawn then, so a later value
/// would say one thing while the SDK did another.
private func merge(_ base: ResolvedOptions, _ update: GroundcoverOptionsUpdate) -> ResolvedOptions {
    var merged = base
    merged.sessionMaxDurationMs = normalizeSessionMaxDuration(
        update.sessionMaxDuration, current: base.sessionMaxDurationMs)
    merged.debug = update.debug ?? base.debug
    merged.excludedUrls = update.excludedUrls ?? base.excludedUrls
    merged.beforeSend = update.beforeSend ?? base.beforeSend
    merged.enrichEvent = update.enrichEvent ?? base.enrichEvent
    merged.privacy = mergePrivacy(base.privacy, update.privacy)
    merged.tracing = base.tracing.merging(update.tracing)
    merged.transport = mergeTransport(base.transport, update.transport)
    return merged
}

private func mergePrivacy(_ base: PrivacyOptions, _ update: PrivacyOptions?) -> PrivacyOptions {
    guard let update else { return base }
    return PrivacyOptions(
        level: update.level ?? base.level,
        maskNetworkBodies: update.maskNetworkBodies ?? base.maskNetworkBodies,
        maskNetworkQueryParams: update.maskNetworkQueryParams ?? base.maskNetworkQueryParams,
        maskLogs: update.maskLogs ?? base.maskLogs,
        maskErrors: update.maskErrors ?? base.maskErrors,
        sensitiveKeys: update.sensitiveKeys ?? base.sensitiveKeys,
        redact: update.redact ?? base.redact,
        maskInteractionLabels: update.maskInteractionLabels ?? base.maskInteractionLabels)
}

private func mergeTransport(_ base: TransportOptions, _ update: TransportOptions?)
    -> TransportOptions
{
    guard let update else { return base }
    return TransportOptions(
        batchSize: update.batchSize ?? base.batchSize,
        batchTimeout: update.batchTimeout ?? base.batchTimeout,
        compression: update.compression ?? base.compression)
}

/// `update` merged into `base`: the fields it gives replace the current ones, and the rest stay.
/// New properties are made JSON data here, once, rather than on every batch envelope that carries
/// them.
private func mergeUser(_ base: RumUser?, _ update: RumUser) -> RumUser {
    RumUser(
        id: update.id ?? base?.id,
        email: update.email ?? base?.email,
        name: update.name ?? base?.name,
        role: update.role ?? base?.role,
        organization: update.organization ?? base?.organization,
        properties: update.properties.map { toJsonMap($0) } ?? base?.properties)
}
