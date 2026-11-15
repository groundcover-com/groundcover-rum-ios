import Foundation
import ObjectiveC

/// Records the requests URLSession's classic loader sends, with no change to the app's code, from
/// two swizzles of `NSURLSessionTask`, the methods other network instrumentation hooks too.
/// `resume` starts a recording and gives the request its trace headers, unless it already carries
/// its own traceparent; the `setState:` that completes the task ends it. That covers
/// completion handlers, delegates, `async` calls, uploads and downloads, `URLSession.shared`, and
/// the clients built on URLSession, such as Alamofire. The response body is never read: it is
/// reported unavailable. An upload's body is the task's, not its request's, so it is named by its
/// content type, or reported unavailable.
///
/// Not seen: a session that opts into the new loader (`usesClassicLoadingMode = false`), whose
/// tasks are another class, and streams and WebSockets. A request the explicit API or
/// ``Groundcover/startNetworkRecording(_:)`` records is left to it.
final class URLSessionTaskObserver: @unchecked Sendable {
    static let shared = URLSessionTaskObserver()

    private let lock = NSLock()
    private var runtime: RumRuntime?
    private var installed = false

    /// Installs both swizzles, once per process, from the main thread. They are never removed:
    /// whoever swizzled after us calls them, so they stay and go quiet when ``disarm()`` runs.
    func install() {
        guard !installed else { return }
        installed = true
        let resume = #selector(URLSessionTask.resume)
        typealias Resume = @convention(c) (AnyObject, Selector) -> Void
        _ = Swizzle.replace(URLSessionTask.self, resume, signature: "v@:") { previous in
            let original = unsafeBitCast(previous, to: Resume.self)
            let replacement: @convention(block) (AnyObject) -> Void = { task in
                // Before the original: the request goes out as resume leaves it.
                if let task = task as? URLSessionTask {
                    URLSessionTaskObserver.shared.resuming(task)
                }
                original(task, resume)
            }
            return replacement
        }
        let setState = NSSelectorFromString("setState:")
        typealias SetState = @convention(c) (AnyObject, Selector, Int) -> Void
        _ = Swizzle.replace(URLSessionTask.self, setState, signature: "v@:q") { previous in
            let original = unsafeBitCast(previous, to: SetState.self)
            let replacement: @convention(block) (AnyObject, Int) -> Void = { task, state in
                original(task, setState, state)
                if state == URLSessionTask.State.completed.rawValue,
                    let task = task as? URLSessionTask
                {
                    URLSessionTaskObserver.shared.completed(task)
                }
            }
            return replacement
        }
    }

    func arm(_ runtime: RumRuntime) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        runtime = nil
        lock.unlock()
    }

    /// A task is about to start. Only its first resume counts: a later one, after a suspend, finds
    /// the request already on its way, and CFNetwork may be writing to it.
    func resuming(_ task: URLSessionTask) {
        lock.lock()
        let runtime = self.runtime
        lock.unlock()
        // Streams and WebSockets are long-lived connections, and AVFoundation's download tasks
        // throw when their request is read: only data tasks, uploads among them, and download
        // tasks.
        guard let runtime, task.state == .suspended,
            task is URLSessionDataTask || task is URLSessionDownloadTask,
            objc_getAssociatedObject(task, &recordingKey) == nil
        else { return }
        objc_setAssociatedObject(task, &recordingKey, NSNull(), .OBJC_ASSOCIATION_RETAIN)
        guard let request = task.currentRequest, !NetworkRecorder.isRecorded(request) else {
            return
        }
        let (outgoing, recorder) = NetworkRecorder.start(
            request, bodyInTask: task is URLSessionUploadTask, runtime: runtime)
        guard let recorder else { return }
        if outgoing.allHTTPHeaderFields != request.allHTTPHeaderFields {
            send(outgoing, for: task)
        }
        objc_setAssociatedObject(
            task, &recordingKey, GroundcoverNetworkRecording(recorder, runtime: runtime),
            .OBJC_ASSOCIATION_RETAIN)
    }

    /// The task completed: its recording ends with the task's response or error.
    func completed(_ task: URLSessionTask) {
        guard
            let recording = objc_getAssociatedObject(task, &recordingKey)
                as? GroundcoverNetworkRecording
        else { return }
        recording.finish(response: task.response, data: nil, error: task.error)
    }

    /// Makes `request` the one the task sends, through the task's private setter, as a new
    /// request: CFNetwork may read the task's own at any time, so it is never changed in place.
    /// Skipped, and the request goes out without its trace headers, when the task's class has no
    /// setter of the type expected.
    private func send(_ request: URLRequest, for task: URLSessionTask) {
        let selector = NSSelectorFromString("setCurrentRequest:")
        guard let cls = object_getClass(task),
            let method = Swizzle.method(cls, selector, signature: "v@:@", inherited: true)
        else {
            RumDiagnostics.shared.log(
                "[capture] \(NSStringFromClass(type(of: task))) can't take a new request; "
                    + "sent without trace headers")
            return
        }
        typealias Setter = @convention(c) (AnyObject, Selector, NSURLRequest) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(task, selector, request as NSURLRequest)
    }
}

private var recordingKey: UInt8 = 0
