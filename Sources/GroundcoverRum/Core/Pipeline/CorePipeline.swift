import Foundation

/// Which event types prove a user is present.
let activityEventTypes: Set<String> = ["interaction"]

/// Heartbeat-style types that never drive session reconciliation.
let ignoredEventTypes: Set<String> = ["performance"]

/// Types that never trigger a size flush; they ride with the next one.
let eventsToSkipFlush: Set<String> = ["navigation", "interaction", "performance"]

/// Attributes the pipeline stamps on every event, which user-supplied log attributes may not
/// shadow.
let reservedAttributeKeys = ["screen"]

/// The pipeline behind the public API: session, shaping, the hooks, enrichment and batching, the
/// twin of the Flutter SDK's DartRumPipeline. Confined to the core queue.
final class CorePipeline {
    private let ids: IdGenerator
    private let diagnostics: RumDiagnostics
    private let marks: InteractiveMarks
    private var config: ConfigManager?
    private var platform: PlatformServices?
    private var running: Running?
    private var outcome: PipelineStart?
    private var stopped = false

    /// What waits on the crash drain in flight: one pass at a time, since a second would read the
    /// same un-acked records and send them twice.
    private var drainWaiters: [() -> Void]?

    /// Runs on the core queue after the pipeline acted on the engine, which no call of the app's
    /// went through: an event can rotate the session, and the runtime publishes the id again.
    var onEngineWork: (() -> Void)?

    init(
        idGenerator: IdGenerator = RandomIdGenerator(), diagnostics: RumDiagnostics = .shared,
        marks: InteractiveMarks = InteractiveMarks()
    ) {
        self.ids = idGenerator
        self.diagnostics = diagnostics
        self.marks = marks
    }

    /// Builds the session and starts batching, once: a second call answers as the first did.
    func start(_ input: GroundcoverConfig, platform: PlatformServices) -> PipelineStart {
        if let outcome { return outcome }
        diagnostics.configure(debug: input.options.debug ?? false)
        let config = ConfigManager(input)
        self.config = config
        self.platform = platform
        let storage = SafeStorage(platform.storage)
        let session = SessionState(
            storage: storage, maxDurationMs: { config.config.options.sessionMaxDurationMs })
        bootstrapSession(
            session: session, idGenerator: ids, clock: platform.clock,
            providedSessionId: input.sessionId)
        guard
            resolveSamplingDecision(
                storage: storage, sessionSampleRate: config.config.options.sessionSampleRate)
        else {
            diagnostics.log("[pipeline] session is not sampled")
            outcome = .unsampled
            startEngine(recording: false)
            return .unsampled
        }

        let pool = EventsPool(
            config: config, session: session,
            transporter: Transporter(
                config: config, sender: platform.sender, executor: platform.executor,
                diagnostics: diagnostics),
            deviceAttributes: platform.deviceAttributes, eventsToSkipFlush: eventsToSkipFlush,
            executor: platform.executor)
        // Every event carries the screen it happened on, empty before the first navigation.
        let navigation = NavigationTracker()
        let enricher = EventEnricher(
            idGenerator: ids, clock: platform.clock,
            platformAttributes: {
                ["screen": ["name": navigation.screenName, "key": navigation.screenKey]]
            },
            reservedAttributeKeys: reservedAttributeKeys)
        let lifecycle = SessionLifecycle(
            session: session, pool: pool, idGenerator: ids, clock: platform.clock,
            activityEventTypes: activityEventTypes, ignoredEventTypes: ignoredEventTypes)
        lifecycle.install()
        pool.initialize()
        let running = Running(
            config: config, clock: platform.clock, session: session, pool: pool, enricher: enricher,
            lifecycle: lifecycle, navigation: navigation, crashStore: platform.crashStore)
        self.running = running
        if config.config.options.isEnabled(.appStart) {
            running.appStart = AppStartTracker(
                submit: { [weak self] in self?.submit($0) },
                manualTti: config.config.options.native?.tti == .manual, marks: marks,
                executor: platform.executor, diagnostics: diagnostics)
        }
        running.syncSnapshot()
        outcome = .recording
        startEngine(recording: true)
        return .recording
    }

    /// Starts the native engine, unsampled sessions included: crash capture governs the delivery of
    /// an earlier session's crash too (see ``engineConfigJson(_:recording:snapshotJson:)``). Not
    /// waited on: start doesn't wait for native work.
    private func startEngine(recording: Bool) {
        guard let engine = platform?.engine, let executor = platform?.executor, let config else {
            return
        }
        let json = engineConfigJson(
            config.config.options, recording: recording, snapshotJson: running?.snapshot)
        // Before the start: the engine emits from inside it.
        engine.onSignal = { [weak self] kind, payload in
            executor.execute { self?.engineSignal(kind, payload) }
        }
        engine.start(configJson: json) { [weak self] status in
            executor.execute { self?.engineStarted(status, recording: recording) }
        }
    }

    /// A signal from the engine, on the core queue.
    func engineSignal(_ kind: String, _ payload: [String: Any]) {
        guard let running else { return }
        if kind == "app_start" {
            guard let start = appStartOfSignal(payload) else { return }
            running.appStart?.onAppStart(start)
        } else if kind == "frame_segment" {
            // Closed by the engine itself (a trip to the background, the cap): drawn on the screen
            // current now.
            guard
                let segment = frameSegmentOf(
                    payload, screenName: running.navigation.screenName,
                    screenKey: running.navigation.screenKey)
            else { return }
            submit(.frameSegment(segment))
            // Closed as the app leaves, a moment after the background flush went: sent on its
            // own, or the app is often suspended or killed before the batch timer fires.
            if segment.reason == .background { running.pool.flush() }
        } else {
            guard let capture = captureOfSignal(kind, payload) else { return }
            submit(capture)
        }
        onEngineWork?()
    }

    /// The app marked itself interactive (``InteractiveMarks/markManual(nowMs:)``).
    func interactiveMarked() {
        running?.appStart?.reportTtiIfReady()
    }

    private func engineStarted(_ status: NativeEngineStatus, recording: Bool) {
        // Stopped while the engine started: nothing to act for any more.
        guard !stopped else { return }
        // Started, so the previous runs' crashes are harvested: the snapshot may follow the session
        // now, and those crashes are delivered, sampled or not, each under its own session.
        nativeStarted()
        // The app asked for crashes and the engine couldn't oblige: usually another reporter owns
        // the process's crash handling, which the engine refuses to take over. Said out loud, or
        // the app reports no native crashes with nothing to explain it. A session not sampled
        // reports nothing anyway, so it says nothing.
        if let unavailable = status.crashesUnavailable, recording,
            config?.config.options.isEnabled(.crashes) == true
        {
            diagnostics.warn(
                "[groundcover] native crash capture is unavailable: \(unavailable). "
                    + "Native crashes will not be reported for this session.")
        }
    }

    func submit(_ capture: Capture) {
        guard let running else { return }
        let enabled = gate(of: capture).map { running.config.config.options.isEnabled($0) } ?? true
        // A navigation moves the current screen even with navigation events off: every other event
        // is stamped with the screen it happened on, and only the navigation events are left out.
        if case .navigation(let navigation) = capture {
            let left = (name: running.navigation.screenName, key: running.navigation.screenKey)
            let input = running.navigation.handle(
                navigation, nowMs: running.clock(), privacy: running.config.privacy)
            if let input, enabled { running.pool.addEvent(running.enricher.enrich(input)) }
            if running.navigation.screenName != left.name
                || running.navigation.screenKey != left.key
            {
                screenChanged(running, left: left)
            }
            running.syncSnapshot()
            return
        }
        guard enabled else { return }
        if case .frameSegment(let segment) = capture {
            return addFrameSegment(running, segment)
        }
        let privacy = running.config.privacy
        let input: EnrichInput
        switch capture {
        case .custom(let custom):
            input = shapeCustomEvent(custom)
        case .log(let log):
            input = shapeLogEvent(log, privacy: privacy, reservedKeys: reservedAttributeKeys)
        case .error(let error):
            input = shapeErrorEvent(error, privacy: privacy)
        case .network(let network):
            input = shapeNetworkEvent(
                network, privacy: privacy, tracing: running.config.config.options.tracing)
        case .interaction(let interaction):
            input = shapeInteractionEvent(interaction, privacy: privacy)
        case .hang(let hang):
            input = shapeHangEvent(hang)
        case .appStart(let start):
            input = shapeAppStartEvent(start, metricId: ids.generateId())
        case .navigation, .frameSegment:
            return
        }
        running.pool.addEvent(running.enricher.enrich(input))
        // A recovered hang often comes just before a force-quit or an OS kill, which the batch
        // timer would lose it to.
        if case .hang = capture { running.pool.flush() }
        // An event can rotate the session.
        running.syncSnapshot()
    }

    /// The enabledEvents gate `capture` passes through. A custom event is the app's own call, never
    /// gated.
    private func gate(of capture: Capture) -> RumEventName? {
        switch capture {
        case .custom: return nil
        case .log: return .logs
        case .error: return .exceptions
        case .network: return .network
        case .interaction: return .interaction
        case .navigation: return .navigation
        case .hang: return .hangs
        case .appStart: return .appStart
        case .frameSegment: return .vitals
        }
    }

    /// RN's vitals listener: a closed segment, as one `frames_delay_total`.
    private func addFrameSegment(_ running: Running, _ segment: FrameSegmentCapture) {
        // "Nothing rendered" is no vitals signal: an empty segment would report no lost time, as
        // though the screen had been smooth.
        guard segment.total > 0 else { return }
        // The idle gate, as RN's: frames drawn while nobody was there don't describe a session
        // anyone used.
        guard !running.session.isSessionInactive(nowMs: running.clock()) else { return }
        // Started before this session did: part of it measured the session that rotated away, and
        // the pool stamps the session at send time, so it would ship under the new one. A segment
        // drawn wholly since the rotation is this session's own, and so is one that started after
        // the app last left when the return rotated the session: the engine restarts its segment
        // on the return, a moment before the rotation lands here.
        guard
            msToNs(segment.startMs) >= running.session.sessionStartTimeNs
                || startedSinceRotatingReturn(running, segment)
        else { return }
        // An enricher of its own: on a screen change the segment belongs to the screen being left,
        // and the ambient stamp already names the new one.
        let enricher = EventEnricher(
            idGenerator: ids, clock: running.clock,
            platformAttributes: {
                ["screen": ["name": segment.screenName, "key": segment.screenKey]]
            })
        running.pool.addEvent(
            enricher.enrich(shapeFrameSegmentEvent(segment, metricId: ids.generateId())))
    }

    /// Whether `segment` started after the app last left, and the current session is the one the
    /// return that followed rotated to.
    private func startedSinceRotatingReturn(_ running: Running, _ segment: FrameSegmentCapture)
        -> Bool
    {
        running.leftAtMs > 0 && segment.startMs >= running.leftAtMs
            && running.returnSessionStartNs == running.session.sessionStartTimeNs
    }

    /// The stamped screen changed, to a named one, and is current: the first is the automatic TTI
    /// mark, and releases the launch metrics held for it under itself; every later one closes the
    /// frame segment drawn on the screen `left`.
    private func screenChanged(_ running: Running, left: (name: String, key: String)) {
        guard !running.navigation.screenName.isEmpty else { return }
        if marks.markAuto(nowMs: running.clock()) { running.appStart?.reportTtiIfReady() }
        running.appStart?.screenKnown()
        // The first screen closes nothing: the launch is its own, and the engine has had no time
        // to count a frame.
        guard !left.name.isEmpty, running.config.config.options.isEnabled(.vitals),
            let engine = platform?.engine, let executor = platform?.executor
        else { return }
        // Not waited on: a screen change never waits for the engine. Filed under the screen left,
        // passed along rather than read back, since the stamp has moved on by the time it lands.
        engine.flushFrameSegment { [weak self] payload in
            guard let payload else { return }
            executor.execute { self?.frameSegmentClosed(payload, on: left) }
        }
    }

    private func frameSegmentClosed(
        _ payload: [String: Any], on screen: (name: String, key: String)
    ) {
        guard running != nil,
            let segment = frameSegmentOf(payload, screenName: screen.name, screenKey: screen.key)
        else { return }
        submit(.frameSegment(segment))
        onEngineWork?()
    }

    /// What network capture asks before a request goes out, as the configuration is now; nil before
    /// start or when this session isn't recorded.
    var networkPolicy: NetworkPolicy? {
        running.map { NetworkPolicy(config: $0.config.config) }
    }

    /// Whether a request to `url` is captured (``NetworkPolicy/captures(_:)``).
    func capturesUrl(_ url: String) -> Bool {
        networkPolicy?.captures(url) ?? false
    }

    /// The trace headers a request to `url` carries, fresh ids each call.
    func traceHeaders(for url: String) -> [String: String] {
        networkPolicy?.traceHeaders(for: url, ids: ids) ?? [:]
    }

    /// A genuine user signal: confirms the session and opens the send gate.
    func presence() {
        guard let running else { return }
        running.lifecycle.reconcile(nowMs: running.clock(), userPresent: true)
        running.syncSnapshot()
    }

    func lifecycle(_ state: HostLifecycle) {
        guard let running else { return }
        switch state {
        case .foreground:
            let sessionStartNs = running.session.sessionStartTimeNs
            running.lifecycle.reconcile(nowMs: running.clock(), userPresent: true)
            if running.session.sessionStartTimeNs != sessionStartNs {
                running.returnSessionStartNs = running.session.sessionStartTimeNs
            }
        case .inactive:
            running.session.persistLastActivity()
        case .background:
            running.leftAtMs = running.clock()
            running.session.persistLastActivity()
            running.pool.flush()
        }
        running.syncSnapshot()
    }

    /// The current session id; "" before start or when unsampled.
    var sessionId: String { running?.session.sessionId ?? "" }

    /// Sends what the old session buffered, then starts `id` (or a new id).
    func setSessionId(_ id: String?) {
        guard let running else { return }
        running.pool.flushSync()
        running.session.sessionId = id.flatMap { $0.isEmpty ? nil : $0 } ?? ids.generateId()
        running.session.setSessionStartTime(msToNs(running.clock()))
        running.syncSnapshot()
    }

    /// Merges `user` into the identity.
    func identifyUser(_ user: RumUser) {
        updateConfig(GroundcoverConfigUpdate(user: .set(user)))
    }

    func updateConfig(_ update: GroundcoverConfigUpdate) {
        config?.update(update)
        // The SDK's own log follows the flag from this call on.
        if let debug = update.options?.debug { diagnostics.configure(debug: debug) }
        // The envelope may have changed (the user, the cluster, the env).
        running?.configVersion += 1
        running?.syncSnapshot()
    }

    /// Sends the buffer now.
    func flush() {
        running?.pool.flush()
    }

    /// Stops batching and the native engine. Buffered events are dropped; persisted session state
    /// is kept, so the next start continues the session.
    func stop() {
        stopped = true
        if let running {
            running.appStart?.dispose()
            running.lifecycle.uninstall()
            running.pool.destroy()
            // A session that stopped is no longer one to file a crash under.
            running.clearSnapshot()
            self.running = nil
        }
        if outcome != nil {
            platform?.engine?.onSignal = nil
            platform?.engine?.stop()
        }
    }

    /// The session envelope plus the current screen, as JSON: what the native engine files a
    /// crash in this run under. The engine starts with it in its config; nil when this session is
    /// not recorded.
    var sessionSnapshot: String? { running?.snapshot }

    /// The native engine has started, so it has harvested the crashes earlier runs left. Until now
    /// nothing of this run reached it: the harvest pairs those crashes with the snapshot it holds.
    /// From now on the snapshot follows the session, and the harvested crashes are delivered, each
    /// under the session it crashed in, whether or not this session is sampled. `completion` runs
    /// once that pass is over; nothing happens once stopped.
    func nativeStarted(completion: @escaping () -> Void = {}) {
        // Stopped first: the drain would send under a config the app gave up on.
        guard !stopped else { return completion() }
        running?.markEngineStarted()
        guard let config, let platform, let store = platform.crashStore else { return completion() }
        if drainWaiters != nil {
            drainWaiters?.append(completion)
            return
        }
        drainWaiters = [completion]
        drainCrashReports(
            store: store, config: config, ids: ids, clock: platform.clock,
            transporter: Transporter(
                config: config, sender: platform.sender, executor: platform.executor,
                diagnostics: diagnostics)
        ) { [weak self] in
            let waiters = self?.drainWaiters ?? []
            self?.drainWaiters = nil
            for waiter in waiters { waiter() }
        }
    }
}

private final class Running {
    let config: ConfigManager
    let clock: RumClock
    let session: SessionState
    let pool: EventsPool
    let enricher: EventEnricher
    let lifecycle: SessionLifecycle
    let navigation: NavigationTracker
    let crashStore: CrashStore?

    /// Bumped by every config update, which can change the envelope.
    var configVersion = 0

    /// Holds the launch metrics for the first screen, when appStart is on.
    var appStart: AppStartTracker?

    /// When the app last left the foreground, on the core clock; 0 before it first has.
    var leftAtMs: Int64 = 0

    /// The start of the session the last return to the foreground rotated to, if it rotated one.
    var returnSessionStartNs: Int64?

    /// The session to file a crash in this run under. Kept current whether or not it can go out
    /// yet.
    private(set) var snapshot: String?
    private var snapshotKey: String?

    /// Whether the native engine has started. Until it has, nothing of this run may reach it: its
    /// start pairs the previous run's crashes with the snapshot it holds.
    private var engineStarted = false

    init(
        config: ConfigManager, clock: @escaping RumClock, session: SessionState, pool: EventsPool,
        enricher: EventEnricher, lifecycle: SessionLifecycle, navigation: NavigationTracker,
        crashStore: CrashStore?
    ) {
        self.config = config
        self.clock = clock
        self.session = session
        self.pool = pool
        self.enricher = enricher
        self.lifecycle = lifecycle
        self.navigation = navigation
        self.crashStore = crashStore
    }

    /// Rebuilds the snapshot when the session or the config changed, compared by a cheap key first,
    /// since this runs after every capture; pushes it once the engine has started.
    func syncSnapshot() {
        guard let crashStore else { return }
        let key = [
            session.sessionId, String(session.sessionStartTimeNs), String(configVersion),
            navigation.screenName, navigation.screenKey,
        ].joined(separator: "\u{0}")
        if key == snapshotKey { return }
        var envelope = pool.sessionAttributes()
        envelope["screen"] = ["name": navigation.screenName, "key": navigation.screenKey]
        let json = encodeJson(envelope)
        snapshotKey = key
        snapshot = json
        if engineStarted { crashStore.updateSessionSnapshot(json) }
    }

    /// The engine has started: the latest snapshot goes out, and every change after it.
    func markEngineStarted() {
        if engineStarted { return }
        engineStarted = true
        if let snapshot { crashStore?.updateSessionSnapshot(snapshot) }
    }

    /// Not before the engine started: what it holds then is the previous run's envelope, which its
    /// harvest still has to read.
    func clearSnapshot() {
        guard engineStarted else { return }
        crashStore?.updateSessionSnapshot(nil)
    }
}
