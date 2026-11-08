import Foundation

/// Records one request: trace headers on the way out, a network event when it ends. A cancelled
/// request isn't reported, except an event stream that opened: it has no end of its own, so the
/// app ends it by cancelling it.
final class NetworkRecorder: @unchecked Sendable {
    private let method: String
    private let url: String
    private let startMs: Int64
    private let requestHeaders: [String: String]
    private let requestBody: String

    /// Marks a request on its way out as recorded, in the request itself, so the task that sends
    /// it isn't recorded a second time by ``URLSessionTaskObserver``.
    private static let recordedProperty = "com.groundcover.rum.recorded"

    /// The request as it should go out, and its recorder: nil when the SDK isn't recording or the
    /// URL isn't captured, and then the request is untouched. A request that carries its own
    /// traceparent, or another SDK's, in one of the propagation headers keeps it and gains no
    /// trace header; any other gains them all. `bodyInTask` is for an upload task, which holds its
    /// body itself: a request without one doesn't make it empty.
    static func start(
        _ request: URLRequest, bodyInTask: Bool = false, runtime: RumRuntime = .shared
    ) -> (URLRequest, NetworkRecorder?) {
        guard let url = request.url?.absoluteString, let policy = runtime.networkPolicy,
            policy.captures(url)
        else { return (request, nil) }
        var outgoing = request
        if !policy.tracing.traceparentHeaders.contains(where: {
            request.value(forHTTPHeaderField: $0) != nil
        }) {
            for (name, value) in policy.traceHeaders(for: url, ids: RandomIdGenerator()) {
                outgoing.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let marked = (outgoing as NSURLRequest).mutableCopy() as? NSMutableURLRequest {
            URLProtocol.setProperty(true, forKey: recordedProperty, in: marked)
            outgoing = marked as URLRequest
        }
        var headers: [String: String] = [:]
        for (name, value) in outgoing.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        let recorder = NetworkRecorder(
            method: outgoing.httpMethod ?? "GET", url: url, startMs: runtime.nowMs,
            requestHeaders: headers,
            requestBody: Self.requestBody(outgoing, bodyInTask: bodyInTask))
        return (outgoing, recorder)
    }

    /// Whether `request` came from ``start(_:runtime:)``: its recorder reports it.
    static func isRecorded(_ request: URLRequest) -> Bool {
        URLProtocol.property(forKey: recordedProperty, in: request) != nil
    }

    private init(
        method: String, url: String, startMs: Int64, requestHeaders: [String: String],
        requestBody: String
    ) {
        self.method = method
        self.url = url
        self.startMs = startMs
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
    }

    /// The request ended with `response` and `data`, nil when the body wasn't read, or with
    /// `error`.
    func finish(
        response: URLResponse?, data: Data?, error: Error?, runtime: RumRuntime = .shared
    ) {
        let http = response as? HTTPURLResponse
        var error = error
        if let urlError = error as? URLError, urlError.code == .cancelled {
            guard let http, isEventStream(http.value(forHTTPHeaderField: "Content-Type") ?? "")
            else { return }
            error = nil
        }
        var capture = NetworkCapture(
            method: method, url: url, startMs: startMs, endMs: runtime.nowMs,
            status: error == nil ? http?.statusCode ?? 0 : 0, requestHeaders: requestHeaders,
            requestBody: requestBody)
        if let error {
            capture.errorType = (error as? URLError)?.code == .timedOut ? .timeout : .networkFailure
        } else if let http {
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                headers["\(name)".lowercased()] = "\(value)"
            }
            capture.responseHeaders = headers
            capture.responseBody = Self.responseBody(
                data, method: method, status: http.statusCode, headers: headers)
        }
        runtime.dispatch("network") { $0.submit(.network(capture)) }
    }

    /// The request's body as text, or a placeholder: a stream isn't read, a binary one is named
    /// by its type, and one at or past the cap is too large. With `bodyInTask`, a request without
    /// a body is named by its type, or else unavailable, since the body the task sends is unseen.
    static func requestBody(_ request: URLRequest, bodyInTask: Bool = false) -> String {
        if request.httpBodyStream != nil { return BodyPlaceholder.requestUnavailable }
        let contentType = request.value(forHTTPHeaderField: "content-type") ?? ""
        guard let data = request.httpBody, !data.isEmpty else {
            return bodyInTask ? classifyBody(contentType) ?? BodyPlaceholder.requestUnavailable : ""
        }
        return text(data, contentType: contentType, tooLarge: BodyPlaceholder.requestTooLarge)
    }

    static func responseBody(_ data: Data?, method: String, status: Int, headers: [String: String])
        -> String
    {
        if isKnownEmptyResponse(method: method, status: status, headers: headers) { return "" }
        let contentType = headers["content-type"] ?? ""
        if isEventStream(contentType) { return BodyPlaceholder.responseUnreadable }
        guard let data else { return BodyPlaceholder.responseUnavailable }
        guard !data.isEmpty else { return "" }
        return text(data, contentType: contentType, tooLarge: BodyPlaceholder.responseTooLarge)
    }

    private static func text(_ data: Data, contentType: String, tooLarge: String) -> String {
        if let placeholder = classifyBody(contentType) { return placeholder }
        if data.count >= maxNetworkBodyBytes { return tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { return BodyPlaceholder.binary }
        return capBody(text, maxBytes: maxNetworkBodyBytes, tooLargePlaceholder: tooLarge)
    }
}
