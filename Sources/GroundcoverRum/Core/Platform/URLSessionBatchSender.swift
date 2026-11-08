import Foundation
import UIKit

/// Keeps the app running until an upload ends: begins, and returns what ends it.
typealias UploadKeepAlive = () -> () -> Void

/// A background task per upload, so the batch the app flushes on its way to the background still
/// goes out before iOS suspends it.
let backgroundTaskKeepAlive: UploadKeepAlive = {
    let lock = NSLock()
    var task = UIBackgroundTaskIdentifier.invalid
    let end = {
        lock.lock()
        let ending = task
        task = .invalid
        lock.unlock()
        if ending != .invalid { UIApplication.shared.endBackgroundTask(ending) }
    }
    let begun = UIApplication.shared.beginBackgroundTask(
        withName: "com.groundcover.rum.upload", expirationHandler: end)
    lock.lock()
    task = begun
    lock.unlock()
    return end
}

/// Sends batches over a session of the SDK's own: ephemeral (no cookies or cache shared with the
/// app), 30 s per request, two connections, its callbacks on a serial queue of its own.
final class URLSessionBatchSender: BatchSender {
    private let session: URLSession
    private let keepAlive: UploadKeepAlive

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        keepAlive: @escaping UploadKeepAlive = { {} }
    ) {
        self.keepAlive = keepAlive
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.name = "com.groundcover.rum.sender"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: queue)
    }

    func send(endpoint: String, request: BatchRequest, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: endpoint), url.scheme != nil else {
            completion(false)
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        let endKeepAlive = keepAlive()
        session.dataTask(with: urlRequest) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            endKeepAlive()
            completion(error == nil && (200..<300).contains(status))
        }.resume()
    }
}
