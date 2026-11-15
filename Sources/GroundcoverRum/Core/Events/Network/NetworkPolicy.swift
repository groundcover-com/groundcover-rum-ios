import Foundation

/// What network capture asks before a request goes out: whether it is captured, and which trace
/// headers it carries. An immutable copy of the configuration as it is now, which the core queue
/// publishes after every change, so capture reads it on the caller's thread without waiting.
struct NetworkPolicy {
    let enabled: Bool
    let endpoint: String
    let excludedUrls: [URLPattern]
    let tracing: ResolvedTracing

    init(config: SdkConfig) {
        enabled = config.options.isEnabled(.network)
        endpoint = config.endpoint
        excludedUrls = config.options.excludedUrls
        tracing = config.options.tracing
    }

    /// Whether a request to `url` is captured: never the SDK's own upload, nor an `excludedUrls`
    /// match. Capture may report a URL as given or normalized (an HTTP client may lowercase the
    /// host, drop a default port and resolve dot segments), so the endpoint is matched both ways:
    /// captured, each upload would fill the next batch, and an idle app would upload forever.
    func captures(_ url: String) -> Bool {
        guard enabled else { return false }
        if let normalizedEndpoint = normalizedUrl(endpoint), let normalized = normalizedUrl(url),
            normalized.contains(normalizedEndpoint)
        {
            return false
        }
        return !shouldIgnoreUrl(url, endpoint: endpoint, excludedUrls: excludedUrls)
    }

    /// The trace headers a request to `url` carries, fresh ids each call: empty unless it matches
    /// `tracing.propagationUrls`.
    func traceHeaders(for url: String, ids: IdGenerator) -> [String: String] {
        guard matchesPropagationUrl([url], tracing.propagationUrls) else { return [:] }
        return buildTraceHeaders(tracing, generateTraceIds(ids))
    }
}

/// `url` with its scheme and host lowercased, a default port dropped and dot segments resolved.
private func normalizedUrl(_ url: String) -> String? {
    guard var components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased()
    else { return nil }
    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
    {
        components.port = nil
    }
    var segments: [Substring] = []
    for segment in components.path.split(separator: "/", omittingEmptySubsequences: false) {
        if segment == "." { continue }
        if segment == ".." {
            if segments.count > 1 { segments.removeLast() }
            continue
        }
        segments.append(segment)
    }
    components.path = segments.joined(separator: "/")
    return components.string
}
