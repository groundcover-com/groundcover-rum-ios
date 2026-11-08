import Foundation

/// The SDK's process-wide state behind ``Groundcover``: the pipeline, once started, and the core
/// queue every call hops to. Calls before ``start(_:)`` are dropped; so are calls an app's hook
/// makes while the SDK runs it, which would run that hook again, without end.
final class RumRuntime: @unchecked Sendable {
    static let shared = RumRuntime(makePlatform: RumRuntime.devicePlatform)

    private var makePlatform: (GroundcoverConfig) -> PlatformServices
    private let diagnostics: RumDiagnostics
    private let lock = NSLock()
    private var executor: CoreExecutor?
    private var pipeline: CorePipeline?
    private var clock: RumClock = systemClock
    private var cachedSessionId = ""
    private var startOutcome: PipelineStart?
    private var cachedNetworkPolicy: NetworkPolicy?

    init(
        makePlatform: @escaping (GroundcoverConfig) -> PlatformServices,
        diagnostics: RumDiagnostics = .shared
    ) {
        self.makePlatform = makePlatform
        self.diagnostics = diagnostics
    }

    /// Swaps how ``start(_:)`` builds the platform, and returns the one it replaced: for tests that
    /// drive the public API into a fake platform.
    @discardableResult
    func replacePlatform(_ make: @escaping (GroundcoverConfig) -> PlatformServices)
        -> (GroundcoverConfig) -> PlatformServices
    {
        lock.lock()
        defer { lock.unlock() }
        let previous = makePlatform
        makePlatform = make
        return previous
    }

    /// Starts the SDK. Synchronous: it validates and throws on a bad config, then runs the rest on
    /// the core queue and waits for it, at most a second, so the session id is there when it
    /// returns (an app tags its crash reporter with it at once) and a call made after it runs after
    /// it. A second start is ignored, and says so by returning false.
    @discardableResult
    func start(_ config: GroundcoverConfig) throws -> Bool {
        if config.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GroundcoverInitError("start requires a nonblank appId")
        }
        lock.lock()
        if pipeline != nil {
            lock.unlock()
            diagnostics.log("start: the SDK has already started; ignored")
            return false
        }
        diagnostics.configure(debug: config.options.debug ?? false)
        let platform = makePlatform(config)
        // The process's marks: markAppInteractive records into them before start, too.
        let pipeline = CorePipeline(diagnostics: diagnostics, marks: .shared)
        pipeline.onEngineWork = { [weak self, weak pipeline] in
            if let pipeline { self?.publish(pipeline) }
        }
        self.pipeline = pipeline
        executor = platform.executor
        clock = platform.clock
        lock.unlock()
        let startPipeline = { [weak self] in
            let outcome = pipeline.start(config, platform: platform)
            self?.publish(pipeline, outcome: outcome)
        }
        if let queue = platform.executor as? QueueExecutor {
            queue.executeAndWait(timeout: 1, startPipeline)
        } else {
            platform.executor.execute(startPipeline)
        }
        return true
    }

    /// Whether the sampling verdict left this session out, as far as start has heard: capture stays
    /// unarmed then.
    var isUnsampled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startOutcome == .unsampled
    }

    /// What network capture asks before a request goes out, readable from any thread: a value the
    /// core queue publishes after every call, never a wait on it. Nil before start.
    var networkPolicy: NetworkPolicy? {
        lock.lock()
        defer { lock.unlock() }
        return cachedNetworkPolicy
    }

    /// Whether ``start(_:)`` has run, and no reset since.
    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pipeline != nil
    }

    /// The SDK's clock, for stamping a capture on the caller's thread.
    var nowMs: Int64 {
        lock.lock()
        let clock = clock
        lock.unlock()
        return clock()
    }

    /// Runs `work` on the core queue, or drops it, before start or from inside one of the app's
    /// hooks.
    func dispatch(_ name: String, _ work: @escaping (CorePipeline) -> Void) {
        enqueue(name, work, onDrop: nil)
    }

    /// The current session id, readable from any thread, including from inside a hook running on
    /// the core queue: a value the queue publishes, never a wait on it.
    var sessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return cachedSessionId
    }

    /// Sends what the old session buffered, then starts `id` (or a new id); `completion` runs once
    /// that is done, or at once when the call is dropped.
    func setSessionId(_ id: String?, completion: @escaping () -> Void) {
        enqueue(
            "setSessionId", { pipeline in pipeline.setSessionId(id) }, onDrop: completion,
            then: completion)
    }

    /// Stops the SDK and waits for the core queue, at most 5 s, so a later start begins afresh.
    /// From a hook, on that queue, it can't wait, and the stop runs once the hook returns.
    func reset() {
        lock.lock()
        let executor = executor
        let pipeline = pipeline
        self.executor = nil
        self.pipeline = nil
        cachedSessionId = ""
        startOutcome = nil
        cachedNetworkPolicy = nil
        lock.unlock()
        guard let executor, let pipeline else { return }
        if let queue = executor as? QueueExecutor {
            queue.executeAndWait(timeout: 5) { pipeline.stop() }
        } else {
            executor.execute { pipeline.stop() }
        }
    }

    private func enqueue(
        _ name: String, _ work: @escaping (CorePipeline) -> Void, onDrop: (() -> Void)?,
        then: (() -> Void)? = nil
    ) {
        if UserHook.isRunning {
            diagnostics.log("\(name): called from a hook; dropped")
            onDrop?()
            return
        }
        lock.lock()
        let executor = executor
        let pipeline = pipeline
        lock.unlock()
        guard let executor, let pipeline else {
            diagnostics.log("\(name): dropped, the SDK hasn't started")
            onDrop?()
            return
        }
        executor.execute { [weak self] in
            work(pipeline)
            self?.publish(pipeline)
            then?()
        }
    }

    private func publish(_ pipeline: CorePipeline, outcome: PipelineStart? = nil) {
        let id = pipeline.sessionId
        let policy = pipeline.networkPolicy
        lock.lock()
        if self.pipeline === pipeline {
            cachedSessionId = id
            cachedNetworkPolicy = policy
            if let outcome { startOutcome = outcome }
        }
        lock.unlock()
    }

    private static func devicePlatform(_ config: GroundcoverConfig) -> PlatformServices {
        let device = DeviceAttributes(
            appId: config.appId, appVersion: config.options.appVersion,
            appBuild: config.options.appBuild)
        if Thread.isMainThread {
            device.refreshScreen()
        } else {
            DispatchQueue.main.async { device.refreshScreen() }
        }
        return PlatformServices(
            storage: UserDefaultsStorage(), clock: systemClock,
            sender: URLSessionBatchSender(keepAlive: backgroundTaskKeepAlive),
            deviceAttributes: { device.attributes() },
            executor: QueueExecutor(label: "com.groundcover.rum.core"),
            crashStore: DeviceEngine.shared,
            engine: DeviceEngine.shared)
    }
}
