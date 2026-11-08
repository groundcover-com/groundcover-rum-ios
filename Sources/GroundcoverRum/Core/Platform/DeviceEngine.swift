import Foundation

/// The engine compiled into the SDK, behind the pipeline's seams. One per process: the crash
/// reporter and the launch anchors are process-wide, and a start after a stop picks up where the
/// last one left off.
final class DeviceEngine: NativeEngine, CrashStore, GCRumEngineDelegate {
    static let shared = DeviceEngine()

    /// Starts and stops run here, in the order they were asked for. Building the engine reads its
    /// store from disk, and so do installing the crash reporter and harvesting the last run's
    /// crashes, none of which the app's launch should wait on.
    private let queue = DispatchQueue(label: "com.groundcover.rum.engine-host", qos: .utility)
    private let lock = NSLock()
    private var built: GCRumEngine?
    private var signalHandler: ((String, [String: Any]) -> Void)?

    private init() {}

    /// The engine, once the first start has built it.
    private var engine: GCRumEngine? {
        lock.lock()
        defer { lock.unlock() }
        return built
    }

    var onSignal: ((String, [String: Any]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return signalHandler
        }
        set {
            lock.lock()
            signalHandler = newValue
            lock.unlock()
        }
    }

    func start(configJson: String, completion: @escaping (NativeEngineStatus) -> Void) {
        queue.async {
            let config: GCRumEngineConfig
            do {
                config = try GCRumEngineConfig.decode(from: configJson)
            } catch {
                handleError(error)
                completion(NativeEngineStatus())
                return
            }
            let status = (self.engine ?? self.build()).start(config: config)
            completion(
                NativeEngineStatus(
                    crashes: status.crashes, hangs: status.hangs, appStart: status.appStart,
                    vitals: status.vitals, crashesUnavailable: status.crashesUnavailable))
        }
    }

    func stop() {
        queue.async { self.engine?.stop() }
    }

    func flushFrameSegment(completion: @escaping ([String: Any]?) -> Void) {
        guard let engine else { return completion(nil) }
        engine.flushFrameSegmentJson { json in completion(decodeJsonObject(json)) }
    }

    private func build() -> GCRumEngine {
        let engine = GCRumEngine()
        engine.delegate = self
        lock.lock()
        built = engine
        lock.unlock()
        return engine
    }

    func rumEngine(_ engine: GCRumEngine, didEmit kind: String, payload: [String: Any]) {
        onSignal?(kind, payload)
    }

    // The crash store. The pipeline reaches it only once a start has replied, so by then the engine
    // is built.

    func updateSessionSnapshot(_ json: String?) {
        engine?.updateSessionSnapshot(json)
    }

    func pendingCrashReportsJson() -> String {
        engine?.pendingCrashReportsJson() ?? "[]"
    }

    func clearPendingCrashReports(ids: [String]) {
        engine?.clearPendingCrashReports(ids: ids)
    }
}
