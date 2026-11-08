import Foundation

/// One batch POST, as the platform sends it.
struct BatchRequest {
    var headers: [String: String]
    var body: Data
}

/// The one network primitive the core needs; the platform owns how a batch reaches the wire.
protocol BatchSender: AnyObject {
    /// Sends `request`; `completion` says whether it was delivered: the request completed with a
    /// 2xx. Called from any thread.
    func send(endpoint: String, request: BatchRequest, completion: @escaping (Bool) -> Void)
}

/// A batch on its way out: the envelope plus the events, as the wire carries them.
struct Batch {
    var sessionAttributes: [String: Any]
    var events: [[String: Any]]
}

/// Builds each batch's request (JSON, gzip, headers) on the core queue and hands it to the sender.
/// Memory only and no retry: a batch that doesn't land is gone, as in the RN and Flutter SDKs.
final class Transporter {
    private let config: ConfigManager
    private let sender: BatchSender
    private let executor: CoreExecutor
    private let diagnostics: RumDiagnostics

    init(
        config: ConfigManager, sender: BatchSender, executor: CoreExecutor,
        diagnostics: RumDiagnostics = .shared
    ) {
        self.config = config
        self.sender = sender
        self.executor = executor
        self.diagnostics = diagnostics
    }

    /// Fire-and-forget, as a live batch must be.
    func send(_ batch: Batch) {
        guard let outgoing = request(for: batch) else {
            diagnostics.log("No API key found")
            return
        }
        sender.send(endpoint: outgoing.endpoint, request: outgoing.request) {
            [diagnostics] delivered in
            if !delivered { diagnostics.log("Network error while sending batch") }
        }
    }

    /// Sends `batch` and reports, on the core queue, whether it was delivered: the crash drain
    /// deletes a record only once its batch landed. False without an API key, when nothing is sent.
    func deliver(_ batch: Batch, completion: @escaping (Bool) -> Void) {
        guard let outgoing = request(for: batch) else {
            completion(false)
            return
        }
        sender.send(endpoint: outgoing.endpoint, request: outgoing.request) {
            [executor] delivered in
            executor.execute { completion(delivered) }
        }
    }

    private func request(for batch: Batch) -> (endpoint: String, request: BatchRequest)? {
        let config = config.config
        guard !config.apiKey.isEmpty else { return nil }
        let json = encodeJson([
            "sessionAttributes": batch.sessionAttributes, "events": batch.events,
        ])
        if config.options.debug { diagnostics.log("Sending batch:", detail: json) }
        let bytes = Data(json.utf8)
        // A batch that can't be compressed still goes, uncompressed.
        let compressed =
            config.options.transport.compression ?? defaultCompression ? gzip(bytes) : nil
        return (
            "\(config.endpoint)/json/rum",
            BatchRequest(
                headers: [
                    "Content-Type": "application/json",
                    "apikey": config.apiKey,
                    "Content-Encoding": compressed == nil ? "" : "gzip",
                ],
                body: compressed ?? bytes)
        )
    }
}
