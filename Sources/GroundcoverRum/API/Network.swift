import Foundation

// Network capture through the API: a request made through these is reported as a network event,
// and carries trace headers when `tracing.propagationUrls` matches its URL, unless it carries its
// own traceparent. With ``NativeHooks/urlSession`` on, every request URLSession's classic loader
// sends is recorded already, without its response body. These record it with its body, once, and
// record what the hook doesn't see: a session that sets `usesClassicLoadingMode = false`, a client
// not built on URLSession, or any request with the hook off.

extension Groundcover {
    /// Starts recording a request by hand: one from an HTTP client such as Alamofire, with its
    /// response body, or one the URLSession hook doesn't see. `request` gains its trace headers, so
    /// send it as it is now, and call ``GroundcoverNetworkRecording/finish(response:data:error:)``
    /// when it ends. Nil, with `request` untouched, when the SDK isn't recording or doesn't capture
    /// the URL: its own uploads, and `excludedUrls`.
    ///
    /// With Alamofire, an interceptor starts the recording and an event monitor finishes it. The
    /// task's own error, not the `AFError` wrapping it, is what tells a cancel or a timeout apart.
    ///
    /// ```swift
    /// final class GroundcoverMonitor: RequestInterceptor, EventMonitor, @unchecked Sendable {
    ///     private let lock = NSLock()
    ///     private var recordings: [UUID: GroundcoverNetworkRecording] = [:]
    ///
    ///     func adapt(
    ///         _ urlRequest: URLRequest, using state: RequestAdapterState,
    ///         completion: @escaping (Result<URLRequest, any Error>) -> Void
    ///     ) {
    ///         var request = urlRequest
    ///         let recording = Groundcover.startNetworkRecording(&request)
    ///         lock.lock()
    ///         recordings[state.requestID] = recording
    ///         lock.unlock()
    ///         completion(.success(request))
    ///     }
    ///
    ///     func request(
    ///         _ request: Request, didCompleteTask task: URLSessionTask, with error: AFError?
    ///     ) {
    ///         lock.lock()
    ///         let recording = recordings.removeValue(forKey: request.id)
    ///         lock.unlock()
    ///         recording?.finish(
    ///             response: task.response, data: (request as? DataRequest)?.data, error: task.error)
    ///     }
    /// }
    ///
    /// let monitor = GroundcoverMonitor()
    /// let session = Session(interceptor: monitor, eventMonitors: [monitor])
    /// ```
    public static func startNetworkRecording(_ request: inout URLRequest)
        -> GroundcoverNetworkRecording?
    {
        let (outgoing, recorder) = NetworkRecorder.start(request)
        guard let recorder else { return nil }
        request = outgoing
        return GroundcoverNetworkRecording(recorder)
    }
}

/// A request ``Groundcover/startNetworkRecording(_:)`` is recording.
public final class GroundcoverNetworkRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var recorder: NetworkRecorder?
    private let runtime: RumRuntime

    init(_ recorder: NetworkRecorder, runtime: RumRuntime = .shared) {
        self.recorder = recorder
        self.runtime = runtime
    }

    /// The request ended with `response` and `data`, its body (nil when you don't have it), or
    /// with `error`: it is reported as the URLSession methods report theirs, unless it was
    /// cancelled. Call it from any thread; only the first call counts.
    public func finish(response: URLResponse?, data: Data?, error: (any Error)?) {
        lock.lock()
        let recorder = self.recorder
        self.recorder = nil
        lock.unlock()
        recorder?.finish(response: response, data: data, error: error, runtime: runtime)
    }
}

extension URLSession {
    /// `dataTask(with:completionHandler:)`, recorded: `request` gains its trace headers, and the
    /// response, up to the body cap, is reported once `completionHandler` has it.
    public func groundcoverDataTask(
        with request: URLRequest,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        let (outgoing, recorder) = NetworkRecorder.start(request)
        return dataTask(with: outgoing) { data, response, error in
            recorder?.finish(response: response, data: data, error: error)
            completionHandler(data, response, error)
        }
    }

    /// `dataTask(with:)` for a session whose delegate is a ``GroundcoverURLSessionDelegate``:
    /// `request` gains its trace headers, and the delegate reports the response.
    public func groundcoverDataTask(with request: URLRequest) -> URLSessionDataTask {
        let (outgoing, recorder) = NetworkRecorder.start(request)
        let task = dataTask(with: outgoing)
        if let recorder { DelegateRecordings.shared.begin(task, recorder) }
        return task
    }

    /// `data(for:)`, recorded: `request` gains its trace headers, and the response is reported
    /// when it returns or throws.
    public func groundcoverData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (outgoing, recorder) = NetworkRecorder.start(request)
        do {
            let (data, response) = try await data(for: outgoing)
            recorder?.finish(response: response, data: data, error: nil)
            return (data, response)
        } catch {
            recorder?.finish(response: nil, data: nil, error: error)
            throw error
        }
    }
}

/// A session delegate that reports the tasks made with
/// ``Foundation/URLSession/groundcoverDataTask(with:)``. Subclass it for your own session delegate,
/// and call `super` from the two methods below if you override them.
open class GroundcoverURLSessionDelegate: NSObject, URLSessionDataDelegate {
    open func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        DelegateRecordings.shared.received(data, for: dataTask)
    }

    open func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        DelegateRecordings.shared.completed(task, error: error)
    }
}

/// The delegate-session requests in flight, each with the first bytes of its body. Each task
/// carries its own recording, as an associated object, so the recording goes when the task does: a
/// task no delegate ever completes doesn't keep it for good, and a later task allocated at the same
/// address can't find it. The delegate's callbacks arrive on the session's queue, so access is
/// locked.
final class DelegateRecordings: @unchecked Sendable {
    static let shared = DelegateRecordings()

    private final class Recording {
        let recorder: NetworkRecorder
        var body = Data()

        init(_ recorder: NetworkRecorder) { self.recorder = recorder }
    }

    private let lock = NSLock()

    func begin(_ task: URLSessionTask, _ recorder: NetworkRecorder) {
        lock.lock()
        objc_setAssociatedObject(
            task, &delegateRecordingKey, Recording(recorder), .OBJC_ASSOCIATION_RETAIN)
        lock.unlock()
    }

    /// The recorder `task` carries, for tests.
    func recorder(for task: URLSessionTask) -> NetworkRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return recording(of: task)?.recorder
    }

    func received(_ data: Data, for task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        guard let recording = recording(of: task) else { return }
        // Past the cap the body is a placeholder anyway: keep one byte past it, not the rest.
        if recording.body.count <= maxNetworkBodyBytes {
            recording.body.append(data.prefix(maxNetworkBodyBytes + 1 - recording.body.count))
        }
    }

    func completed(_ task: URLSessionTask, error: Error?) {
        lock.lock()
        let recording = recording(of: task)
        objc_setAssociatedObject(task, &delegateRecordingKey, nil, .OBJC_ASSOCIATION_RETAIN)
        let body = recording?.body
        lock.unlock()
        recording?.recorder.finish(response: task.response, data: body, error: error)
    }

    private func recording(of task: URLSessionTask) -> Recording? {
        objc_getAssociatedObject(task, &delegateRecordingKey) as? Recording
    }
}

private var delegateRecordingKey: UInt8 = 0
