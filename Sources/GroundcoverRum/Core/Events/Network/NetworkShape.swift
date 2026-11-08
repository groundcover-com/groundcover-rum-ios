import Foundation

// A captured request as the `network` event the backend ingests. Everything after interception:
// route derivation, query, header and body redaction, body truncation, trace ids and the span name.

/// Request and response headers as sent on the wire: sensitive values redacted, each value
/// truncated. Built-in sensitive headers are always stripped; `allow` only opts out of the user's
/// sensitiveKeys and redactor.
func formatNetworkHeaders(_ headers: [String: String], privacy: EffectivePrivacy) -> [String:
    String]
{
    redactHeaders(headers, privacy.level == .allow ? RedactOptions() : privacy.redactOptions())
        .mapValues { truncate($0) }
}

// RN's absolute-URL path extractor: scheme://authority(/path)?(?#...).
private let urlPath = NSRegularExpression(
    sdkPattern: "^[a-z][a-z0-9+.-]*://[^/?#]*([^?#]*)", options: .caseInsensitive)

/// The route of `url`: its path, without the query; `/` for a root URL. A URL that isn't absolute
/// is kept whole.
func networkPath(_ url: String) -> String {
    let source = url as NSString
    guard
        let match = urlPath.firstMatch(in: url, range: NSRange(location: 0, length: source.length))
    else { return url }
    let range = match.range(at: 1)
    let path = range.location == NSNotFound ? "" : source.substring(with: range)
    return path.isEmpty ? "/" : path
}

func shapeNetworkEvent(
    _ raw: NetworkCapture, privacy: EffectivePrivacy, tracing: ResolvedTracing,
    maxBodyLength: Int = maxNetworkBodyBytes
) -> EnrichInput {
    let queryOpts = privacy.redactOptions(.query)
    var path = networkPath(raw.url)
    var fullUrl = raw.url
    if privacy.shouldMaskNetworkQueryParams {
        // A parsed route has no query (a no-op); an unparseable URL kept whole does.
        path = redactUrl(path, queryOpts)
        fullUrl = redactUrl(fullUrl, queryOpts)
    }

    let method = raw.method.isEmpty ? "UNKNOWN" : raw.method.uppercased()
    // As sent (the caller's case), or UNKNOWN like every other method field.
    let sentMethod = raw.method.isEmpty ? "UNKNOWN" : raw.method
    let status = raw.status.map(String.init)
    let ids = extractTraceIds(raw.requestHeaders, tracing)

    // Redacted before truncating, so the body stays parseable JSON for key-based redaction.
    func body(_ text: String, _ kind: RedactKind) -> String {
        truncate(
            privacy.shouldMaskNetworkBodies ? redactBody(text, privacy.redactOptions(kind)) : text,
            maxLength: maxBodyLength)
    }

    var http: [String: Any] = [
        "route": path,
        "path": path,
        "method": sentMethod,
        "request": [
            "headers": formatNetworkHeaders(raw.requestHeaders, privacy: privacy),
            "method": sentMethod,
        ] as [String: Any],
    ]
    var response: [String: Any] = [
        "headers": formatNetworkHeaders(raw.responseHeaders, privacy: privacy)
    ]
    var attributes: [String: Any] = [
        "type": "HTTP",
        "operation": ["name": method],
        "resource_name": path,
        "subType": method,
        "url": ["full": fullUrl],
        "gc": [
            "request": ["body": body(raw.requestBody, .requestBody)],
            "response": ["body": body(raw.responseBody, .responseBody)],
        ],
    ]
    if let status {
        attributes["status"] = status
        http["status"] = status
        response["status_code"] = status
    }
    http["response"] = response
    attributes["http"] = http
    if let errorType = raw.errorType { attributes["error"] = ["type": errorType.wireName] }

    return EnrichInput(
        type: "network",
        attributes: attributes,
        timestamp: observedAt(raw.startMs),
        endTimestamp: observedAt(raw.endMs),
        // The normalized method, like operation.name: `post` and `POST` are one span.
        spanName: "\(method) \(path)",
        traceId: ids.traceId,
        spanId: ids.spanId)
}

// A capture's clock reading in ns, or nil when it isn't a usable time, so the enricher stamps the
// event instead.
private func observedAt(_ ms: Int64) -> Int64? {
    ms > 0 ? msToNs(ms) : nil
}
