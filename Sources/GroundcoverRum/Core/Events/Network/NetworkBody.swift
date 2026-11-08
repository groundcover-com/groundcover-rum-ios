import Foundation

// Request and response body classification and capping. Reading a body stays with capture;
// deciding whether to read it, and what a body that can't be kept becomes, lives here so every
// platform emits the same placeholders for the same payloads.

/// Emitted in place of a body redaction can't safely handle (binary, oversized, or partial). A
/// truncated prefix would break redactBody, so a body is either complete or a placeholder, never
/// cut.
enum BodyPlaceholder {
    static let requestTooLarge = "[request body too large]"
    static let requestUnavailable = "[request body unavailable]"
    static let responseTooLarge = "[response body too large]"
    static let responseUnavailable = "[response body unavailable]"
    static let responseUnreadable = "[unreadable response body]"
    static let formData = "[form data]"
    static let binary = "[binary data]"
}

/// The bodies kept, in UTF-8 bytes: RN's `maxBodyLength`.
let maxNetworkBodyBytes = 5000

/// MIME essence: the type without parameters, lowercased.
func mimeEssence(_ contentType: String) -> String {
    (contentType.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init)
        ?? "")
        .trimmingCharacters(in: .whitespaces).lowercased()
}

private let structuredSyntax = NSRegularExpression(
    sdkPattern: #"^application/([A-Za-z0-9_.-]+\+)?(json|xml)$"#)

/// Whether a content type is text. Precise rules, not substrings: a `contains("xml")` would pass
/// xlsx and docx. Absent or opaque is not text.
func isTextualContentType(_ contentType: String) -> Bool {
    let mime = mimeEssence(contentType)
    if mime.isEmpty { return false }
    if mime.hasPrefix("text/") { return true }
    if [
        "application/x-www-form-urlencoded", "application/javascript", "application/ecmascript",
        "application/graphql",
    ].contains(mime) {
        return true
    }
    return structuredSyntax.hasMatch(mime)
}

private let archiveTypes: Set<String> = [
    "application/zip", "application/gzip", "application/x-gzip", "application/x-tar",
    "application/x-7z-compressed", "application/x-rar-compressed",
]

/// A fail-closed label for a non-textual content type. Never decoded.
func binaryLabel(_ contentType: String) -> String {
    let mime = mimeEssence(contentType)
    if mime.hasPrefix("image/") { return "[image data]" }
    if mime.hasPrefix("audio/") { return "[audio data]" }
    if mime.hasPrefix("video/") { return "[video data]" }
    if mime.hasPrefix("font/") || mime.hasPrefix("application/font")
        || mime == "application/vnd.ms-fontobject"
    {
        return "[font data]"
    }
    if mime == "application/pdf" { return "[pdf data]" }
    if archiveTypes.contains(mime) { return "[archive data]" }
    if mime == "application/wasm" { return "[wasm data]" }
    if mime.contains("protobuf") || mime.hasPrefix("application/grpc") { return "[protobuf data]" }
    return BodyPlaceholder.binary
}

/// The read gate for a non-empty body: multipart or non-textual gives the placeholder to record
/// without reading it; textual gives nil (read it, capped). A caller that knows the body is empty
/// records "" first.
func classifyBody(_ contentType: String) -> String? {
    let lower = contentType.lowercased()
    if lower.contains("multipart/form-data") { return BodyPlaceholder.formData }
    if !isTextualContentType(lower) { return binaryLabel(lower) }
    return nil
}

/// Whether a response has no body, known without touching it: a HEAD, a null-body status, or
/// `content-length: 0`.
func isKnownEmptyResponse(method: String, status: Int, headers: [String: String]) -> Bool {
    if method.uppercased() == "HEAD" { return true }
    if [204, 205, 304].contains(status) { return true }
    return (headers["content-length"] ?? "").trimmingCharacters(in: .whitespaces) == "0"
}

/// A server-sent-events stream never closes, so its body is never read.
func isEventStream(_ contentType: String) -> Bool {
    mimeEssence(contentType) == "text/event-stream"
}

/// A body, or its too-large placeholder at or over the cap, in UTF-8 bytes.
func capBody(_ text: String, maxBytes: Int, tooLargePlaceholder: String) -> String {
    if text.isEmpty { return text }
    if text.utf16.count >= maxBytes || text.utf8.count >= maxBytes { return tooLargePlaceholder }
    return text
}
