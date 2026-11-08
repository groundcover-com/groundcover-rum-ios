import Foundation

// Generate ids, pick the headers a traced request carries, decide whether a request is traced, and
// read the ids back off a captured request. Setting a header stays with the caller.

struct TraceIds {
    var traceId: String
    var spanId: String

    /// W3C `00-<32 hex>-<16 hex>-01`.
    var traceparent: String

    /// The ids in base 10, for `traceIdHeaderName` and `spanIdHeaderName`.
    var decimalTraceId: String
    var decimalSpanId: String
}

func generateTraceIds(_ ids: IdGenerator) -> TraceIds {
    let spanId = ids.generateSpanId()
    let traceId = ids.generateTraceId()
    return TraceIds(
        traceId: traceId, spanId: spanId, traceparent: "00-\(traceId)-\(spanId)-01",
        decimalTraceId: hexToDecimal(traceId), decimalSpanId: hexToDecimal(spanId))
}

/// `hex` in base 10, exactly, at any length: a trace id is 128 bits. `hex` itself when it isn't
/// hex.
func hexToDecimal(_ hex: String) -> String {
    var digits: [UInt8] = [0]  // base 10, least significant first
    guard !hex.isEmpty else { return hex }
    for character in hex {
        guard let nibble = character.hexDigitValue else { return hex }
        var carry = nibble
        for index in digits.indices {
            let value = Int(digits[index]) * 16 + carry
            digits[index] = UInt8(value % 10)
            carry = value / 10
        }
        while carry > 0 {
            digits.append(UInt8(carry % 10))
            carry /= 10
        }
    }
    while digits.count > 1, digits.last == 0 { digits.removeLast() }
    return String(digits.reversed().map { Character(String($0)) })
}

private let headerToken = NSRegularExpression(sdkPattern: #"^[a-zA-Z0-9!#$&'*+\-.^_`|~]+$"#)

/// RFC 9110 token: a name a host would refuse never reaches a setter.
func isValidHeaderName(_ name: String) -> Bool {
    headerToken.hasMatch(name)
}

/// The headers a traced request carries, by name. Invalid names are dropped; a name configured
/// twice is set once (last wins).
func buildTraceHeaders(_ tracing: ResolvedTracing, _ ids: TraceIds) -> [String: String] {
    var out: [String: String] = [:]
    func set(_ name: String, _ value: String) {
        if isValidHeaderName(name) { out[name] = value }
    }
    if !tracing.origin.name.isEmpty { set(tracing.origin.name, tracing.origin.value) }
    if !tracing.traceIdHeaderName.isEmpty { set(tracing.traceIdHeaderName, ids.decimalTraceId) }
    if !tracing.spanIdHeaderName.isEmpty { set(tracing.spanIdHeaderName, ids.decimalSpanId) }
    for name in tracing.traceparentHeaders { set(name, ids.traceparent) }
    return out
}

private let regexMeta = NSRegularExpression(sdkPattern: #"[.+?^${}()|\[\]\\]"#)

/// Whether a request is traced: any pattern matches any candidate in full. Only `*` is a wildcard;
/// every other metacharacter is escaped, or a `.` would send trace headers to `api-example.com`.
func matchesPropagationUrl(_ candidates: [String], _ patterns: [String]) -> Bool {
    patterns.contains { pattern in
        let escaped = regexMeta.replacingMatches(in: pattern) { groups in "\\" + groups[0] }
            .replacingOccurrences(of: "*", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
        return candidates.contains { regex.hasMatch($0) }
    }
}

/// The trace and span ids a captured request was sent with, or "" for each it lacks. Configured id
/// headers win; otherwise the first propagation header (or `traceparent`) is parsed as W3C. Names
/// match case-insensitively.
func extractTraceIds(_ headers: [String: String], _ tracing: ResolvedTracing)
    -> (traceId: String, spanId: String)
{
    let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    func read(_ name: String) -> String { name.isEmpty ? "" : lower[name.lowercased()] ?? "" }

    var traceId = read(tracing.traceIdHeaderName)
    var spanId = read(tracing.spanIdHeaderName)
    if traceId.isEmpty || spanId.isEmpty {
        var traceparent = tracing.propagationHeaders.lazy.map(read).first { !$0.isEmpty } ?? ""
        if traceparent.isEmpty { traceparent = read("traceparent") }
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "00" {
            if traceId.isEmpty, parts[1].count == 32 { traceId = String(parts[1]) }
            if spanId.isEmpty, parts[2].count == 16 { spanId = String(parts[2]) }
        }
    }
    return (traceId, spanId)
}
