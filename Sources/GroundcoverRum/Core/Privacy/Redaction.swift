import Foundation

// The sensitive-data patterns and redaction helpers every capture path shares. The patterns are
// identical to groundcover's other SDKs, so every SDK masks the same strings. `\w` is spelled out:
// JavaScript's is ASCII, ICU's is Unicode.

let redacted = "[REDACTED]"

/// Header names always redacted, matched case-insensitively in full.
let sensitiveHeaderNames: Set<String> = ["authorization", "cookie", "set-cookie"]

/// Header names match a broader pattern than body and query keys, including the bare `key`
/// substring (x-functions-key, x-api-key, …).
let sensitiveHeaderRegex = NSRegularExpression(
    sdkPattern: "(token|key|secret|passwd|password|auth|bearer|credential)",
    options: .caseInsensitive)

/// Substrings that mark a key sensitive. Specific on purpose: a bare `card`/`session` would hit
/// `cardinality`/`session_id`.
let sensitiveKeyRegex = NSRegularExpression(
    sdkPattern:
        "(token|secret|passwd|password|api[_-]?key|access[_-]?key|write[_-]?key|auth|bearer"
        + "|credential|cvv|ssn|credit[_-]?card|card[_-]?number)",
    options: .caseInsensitive)

/// Query and form keys sensitive on their own but too generic for the substring pattern
/// (`code`/`state` would hit `zipcode`/`statename`). Matched only as whole query or form keys,
/// never inside JSON bodies. Covers the OAuth callback (`?code=…&state=…`).
let sensitiveQueryParamNames: Set<String> = [
    "code", "state", "session_state", "id_token", "access_token", "refresh_token", "token",
]

/// Past this depth values are redacted, so nothing below the limit leaks.
private let maxRedactionDepth = 8

/// Above this length a body or message skips the parse-and-walk path for a single text scrub, so a
/// multi-megabyte payload can't stall a thread.
private let maxBodyParseLength = 100_000

/// What every redaction entry point takes.
struct RedactOptions {
    var sensitiveKeys: [String] = []
    var redact: Redactor?

    /// The event surface, stamped on each ``RedactField`` passed to `redact`.
    var kind: RedactKind?

    func withKind(_ kind: RedactKind) -> RedactOptions {
        RedactOptions(sensitiveKeys: sensitiveKeys, redact: redact, kind: kind)
    }
}

extension EffectivePrivacy {
    /// The redaction options this privacy implies, for the `kind` of surface being redacted.
    func redactOptions(_ kind: RedactKind? = nil) -> RedactOptions {
        RedactOptions(sensitiveKeys: sensitiveKeys, redact: redact, kind: kind)
    }
}

func isSensitiveKey(_ key: String, _ extra: [String] = []) -> Bool {
    if key.isEmpty { return false }
    if sensitiveKeyRegex.hasMatch(key) { return true }
    if extra.isEmpty { return false }
    let lower = key.lowercased()
    return extra.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
}

private func isSensitiveQueryParam(_ key: String, _ extra: [String]) -> Bool {
    sensitiveQueryParamNames.contains(key.lowercased()) || isSensitiveKey(key, extra)
}

// For free text only, the broad header pattern applies to hyphenated keys (x-functions-key,
// set-cookie): on plain prose it would redact `auth: success` or `API key: …`.
private func isHeaderNameKey(_ key: String) -> Bool {
    key.contains("-") && sensitiveHeaderRegex.hasMatch(key)
}

private func isSensitiveTextKey(_ key: String, _ extra: [String]) -> Bool {
    isSensitiveKey(key, extra) || isHeaderNameKey(key)
}

private func isSensitiveFormTextKey(_ key: String, _ extra: [String]) -> Bool {
    isSensitiveQueryParam(key, extra) || isHeaderNameKey(key)
}

// One leaf: `sensitive ? [REDACTED] : value` by default. A hook may override it; returning nil
// (or throwing) keeps the default, so one hook can't switch masking off elsewhere.
private func applyLeaf(_ field: RedactField, _ redact: Redactor?) -> Any? {
    let fallback: Any? = field.sensitive ? redacted : field.value
    guard let redact else { return fallback }
    do {
        return try UserHook.run { try redact(field) } ?? fallback
    } catch {
        handleError(error)
        return fallback
    }
}

private func stringForm(_ value: Any?) -> String {
    guard let value else { return "" }
    return value as? String ?? String(describing: jsonLeaf(value))
}

func redactHeaders(_ headers: [String: String], _ opts: RedactOptions = RedactOptions())
    -> [String: String]
{
    headers.reduce(into: [:]) { out, header in
        let lower = header.key.lowercased()
        let sensitive =
            sensitiveHeaderNames.contains(lower) || sensitiveHeaderRegex.hasMatch(lower)
            || isSensitiveKey(header.key, opts.sensitiveKeys)
        let value = applyLeaf(
            RedactField(
                key: header.key, value: header.value, path: [header.key], kind: .header,
                sensitive: sensitive),
            opts.redact)
        out[header.key] = stringForm(value)
    }
}

// encodeURIComponent's unreserved set.
private let uriComponentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

/// Redacts sensitive values in a `key=value&…` string (no leading `?`), keeping order and
/// duplicate keys.
func redactQueryString(_ search: String, _ opts: RedactOptions = RedactOptions()) -> String {
    if search.isEmpty { return search }
    return search.components(separatedBy: "&").map { pair -> String in
        guard let eq = pair.firstIndex(of: "=") else { return pair }
        let rawKey = String(pair[..<eq])
        let rawValue = String(pair[pair.index(after: eq)...])
        let key = rawKey.removingPercentEncoding ?? rawKey
        let value = rawValue.removingPercentEncoding ?? rawValue
        let out = applyLeaf(
            RedactField(
                key: key, value: value, path: [key], kind: opts.kind ?? .query,
                sensitive: isSensitiveQueryParam(key, opts.sensitiveKeys)),
            opts.redact)
        // Unchanged: keep the original pair, with no decode/re-encode drift.
        if let unchanged = out as? String, unchanged == value { return pair }
        let encoded =
            stringForm(out).addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? ""
        return "\(rawKey)=\(encoded)"
    }.joined(separator: "&")
}

private let userinfo = NSRegularExpression(sdkPattern: "^([a-zA-Z][A-Za-z0-9_+.-]*://)[^/?#@]*@")

// Strips `user:pass@` from an absolute URL's authority, so embedded basic-auth never ships. An `@`
// in a path or query (`?email=a@b.com`) is untouched.
private func redactUserinfo(_ url: String) -> String {
    userinfo.replacingMatches(in: url) { groups in "\(groups[1])\(redacted)@" }
}

private func redactUrlSegment(_ segment: String, _ opts: RedactOptions) -> String {
    guard let queryIndex = segment.firstIndex(of: "?") else { return segment }
    let query = segment[segment.index(after: queryIndex)...]
    return "\(segment[..<queryIndex])?\(redactQueryString(String(query), opts))"
}

/// Redacts sensitive query parameters in a full or relative URL, including a query inside the
/// fragment (`…#/reset?token=…`), and strips userinfo.
func redactUrl(_ url: String, _ opts: RedactOptions = RedactOptions()) -> String {
    if url.isEmpty { return url }
    let queryOpts = opts.withKind(opts.kind ?? .query)
    guard let hashIndex = url.firstIndex(of: "#") else {
        return redactUrlSegment(redactUserinfo(url), queryOpts)
    }
    let beforeHash = String(url[..<hashIndex])
    let fragment = String(url[url.index(after: hashIndex)...])
    return "\(redactUrlSegment(redactUserinfo(beforeHash), queryOpts))#"
        + redactUrlSegment(fragment, queryOpts)
}

// Walks a value, redacting leaves. Containers are recursed and never passed to the hook; a
// sensitive key whose value is a container redacts the subtree whole. Anything that is neither a
// container nor a JSON primitive is stringified first, so the hook only ever sees primitives.
private func redactValue(
    key: String, value: Any?, path: [String], opts: RedactOptions, depth: Int,
    seen: inout Set<ObjectIdentifier>
) -> Any {
    // An Optional inside `[String: Any]` arrives boxed: none would print as "nil".
    let value = unwrapped(value)
    let sensitive = !key.isEmpty && isSensitiveKey(key, opts.sensitiveKeys)
    // A set is walked as a list, as the enricher flattens it.
    let container: Any? = value.flatMap { value in
        value is JsJsonObject || value is [AnyHashable: Any] || value is [Any]
            || value is Set<AnyHashable> || value is NSSet ? value : nil
    }

    if let container {
        if sensitive || depth > maxRedactionDepth { return redacted }
        // Only a true cycle (a container inside itself) is redacted; a value shared between
        // siblings is still walked.
        let identity =
            type(of: container) is AnyClass ? ObjectIdentifier(container as AnyObject) : nil
        if let identity {
            guard seen.insert(identity).inserted else { return redacted }
        }
        defer {
            if let identity { seen.remove(identity) }
        }
        if let object = container as? JsJsonObject {
            return JsJsonObject(
                entries: object.entries.map { entry in
                    (
                        entry.key,
                        redactValue(
                            key: entry.key, value: entry.value, path: path + [entry.key],
                            opts: opts, depth: depth + 1, seen: &seen)
                    )
                })
        }
        if let dictionary = container as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            for (rawKey, child) in dictionary {
                let childKey = "\(rawKey.base)"
                out[childKey] = redactValue(
                    key: childKey, value: child, path: path + [childKey], opts: opts,
                    depth: depth + 1, seen: &seen)
            }
            return out
        }
        return (elements(of: container) ?? []).map { item in
            redactValue(
                key: key, value: item, path: path, opts: opts, depth: depth + 1, seen: &seen)
        }
    }

    let leaf: Any? = value.flatMap { value in
        let json = jsonLeaf(value)
        if json is NSNull { return nil }
        // A struct or class printed as text can carry `password: …` that no key here names. The
        // hook still sees the leaf once, below.
        if let text = json as? String, !(value is String) {
            let scrub = RedactOptions(
                sensitiveKeys: opts.sensitiveKeys, redact: nil, kind: opts.kind)
            return redactText(text, scrub)
        }
        return json
    }
    let out = applyLeaf(
        RedactField(
            key: key, value: leaf, path: path, kind: opts.kind ?? .log, sensitive: sensitive),
        opts.redact)
    return out ?? NSNull()
}

// The quoted value is unrolled (`"[^"\\]*(?:\\.[^"\\]*)*"`): the same strings as JavaScript's
// `"(?:[^"\\]|\\.)*"`, without a backtracking frame per character, which would overflow the JVM's
// regex stack on a large body. Kept identical to the Kotlin twin's.
private let jsonPair = NSRegularExpression(
    sdkPattern: #""([A-Za-z0-9_.-]{1,64})"["# + jsWhitespaceClass + #"]*:["# + jsWhitespaceClass
        + #"]*("[^"\\]*(?:\\.[^"\\]*)*"|[^"# + jsWhitespaceClass + #",}\]]+)"#)
// `?` separates too, so an embedded query (`next=/p?token=secret`) is split instead of swallowed
// whole under a harmless outer key.
private let formPair = NSRegularExpression(
    sdkPattern: "([A-Za-z0-9_.-]{1,64})=([^" + jsWhitespaceClass + "&,;?]+)")
private let colonPair = NSRegularExpression(
    sdkPattern: "([A-Za-z0-9_.-]{1,64}):([ \\t]*)([^\\n,;&]{1,4096})")

/// How deep the `key: value` scrub looks into a value for more pairs: a printed dictionary nests
/// them (`headers: {Authorization: …}`).
private let maxColonPairDepth = 8

/// Redacts sensitive `key: value` pairs in `text`. A harmless key's value is scanned again, since
/// in a printed dictionary (`{k: v, …}`) the pair that matters sits inside a value a label before
/// it swallowed.
private func scrubColonPairs(_ text: String, _ keys: [String], _ depth: Int) -> String {
    colonPair.replacingMatches(in: text) { groups in
        let key = groups[1]
        if isSensitiveTextKey(key, keys) { return "\(key): \(redacted)" }
        if depth >= maxColonPairDepth { return groups[0] }
        return "\(key):\(groups[2])\(scrubColonPairs(groups[3], keys, depth + 1))"
    }
}

/// Free-text scrub for log and error messages and non-JSON bodies: redacts the value in sensitive
/// `key=value`, `key: value` and `"key":"value"` pairs, then hands the whole original string to
/// the redact hook once. Never throws.
func redactText(_ text: String, _ opts: RedactOptions = RedactOptions()) -> String {
    if text.isEmpty { return text }
    // On a very large string, scrub the head and drop the tail (fail-closed).
    if text.utf16.count > maxBodyParseLength {
        return redactText(truncate(text, maxLength: maxBodyParseLength), opts) + "…"
    }

    // The hook sees the whole original string once; a non-nil result replaces the built-in
    // scrub, which then needn't run.
    if let redact = opts.redact {
        do {
            let field = RedactField(
                key: "", value: text, path: [], kind: opts.kind ?? .log, sensitive: false)
            if let result = try UserHook.run({ try redact(field) }) {
                return stringForm(result)
            }
        } catch {
            handleError(error)
        }
    }

    let keys = opts.sensitiveKeys
    if !mayHoldSensitiveKey(text, keys) { return text }
    var out = jsonPair.replacingMatches(in: text) { groups in
        isSensitiveTextKey(groups[1], keys) ? "\"\(groups[1])\":\"\(redacted)\"" : groups[0]
    }
    out = formPair.replacingMatches(in: out) { groups in
        isSensitiveFormTextKey(groups[1], keys) ? "\(groups[1])=\(redacted)" : groups[0]
    }
    return scrubColonPairs(out, keys, 0)
}

/// Every key the scrub redacts contains one of these, or one of the app's extra keys: whole query
/// keys (`code`, `state`, `…token`), the key and header patterns (`api_key` and `x-functions-key`
/// both hold `key`). Keys are ASCII, so a text holding none of them has nothing to scrub, and
/// skips the three passes, most of what a log line costs.
private let sensitiveKeyPart = NSRegularExpression(
    sdkPattern: "token|secret|passw|key|auth|bearer|credential|cvv|ssn|card|code|state",
    options: .caseInsensitive)

private func mayHoldSensitiveKey(_ text: String, _ extra: [String]) -> Bool {
    if sensitiveKeyPart.hasMatch(text) { return true }
    if extra.isEmpty { return false }
    let lower = text.lowercased()
    return extra.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
}

/// Redacts an already-stringified body: JSON deep redaction when it parses, then form encoding,
/// then the free-text scrub. JSON nested too deep to walk is redacted whole. Never throws.
func redactBody(_ body: String, _ opts: RedactOptions = RedactOptions()) -> String {
    if body.isEmpty { return body }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.utf16.count <= maxBodyParseLength, trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
        if let parsed = parseJsJson(trimmed) {
            var seen = Set<ObjectIdentifier>()
            return writeJsJson(
                redactValue(key: "", value: parsed, path: [], opts: opts, depth: 0, seen: &seen))
        }
        // The text scrub can't reach a pair nested under an unquoted value it swallows whole.
        if jsJsonNestsDeeperThan(trimmed, maxJsJsonDepth) { return redacted }
    }
    if body.contains("="), !body.contains("{") { return redactQueryString(body, opts) }
    return redactText(body, opts)
}

/// Deep redaction of structured attributes (log attributes, error metadata). Returns a new
/// dictionary and never mutates the input.
func redactObject(_ object: [String: Any], _ opts: RedactOptions = RedactOptions()) -> [String: Any]
{
    var seen = Set<ObjectIdentifier>()
    return redactValue(key: "", value: object, path: [], opts: opts, depth: 0, seen: &seen)
        as? [String: Any] ?? [:]
}

/// Caller-supplied metadata as it may be sent: key-redacted while masking is on, untouched under
/// `allow`.
func redactMetadata(_ metadata: [String: Any]?, _ privacy: EffectivePrivacy) -> [String: Any]? {
    guard let metadata, privacy.level != .allow else { return metadata }
    return redactObject(metadata, privacy.redactOptions())
}

/// Log-surface redaction (the free-text message and the structured attributes) in one place, for
/// captured and explicit logs alike. A no-op when log masking is off.
func redactLogFields(_ privacy: EffectivePrivacy, message: String, attributes: [String: Any]?)
    -> (message: String, attributes: [String: Any]?)
{
    guard privacy.shouldMaskLogs else { return (message, attributes) }
    let opts = privacy.redactOptions(.log)
    return (redactText(message, opts), attributes.map { redactObject($0, opts) })
}
