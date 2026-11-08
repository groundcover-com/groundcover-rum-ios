import Foundation

/// Events held while the send gate is closed (no presence yet), or while there is no cluster to
/// send under. Bounds a never-confirmed session (real sessions confirm in seconds) and a cluster
/// that never arrives. On overflow the newest is dropped, keeping the earliest.
let maxGatedBufferEvents = 500

/// An explicit 0 is honoured (every event flushes); anything negative falls back to the default, so
/// a bad value can't switch size flushing off.
private func resolveBatchSize(_ value: Int?) -> Int {
    guard let value, value >= 0 else { return defaultBatchSize }
    return value
}

/// Zero is not honoured, nor anything that rounds to it: a 0 ms timer would busy-flush.
private func resolveBatchTimeoutMs(_ seconds: TimeInterval?) -> Int64 {
    guard let seconds, seconds.isFinite else { return defaultBatchTimeoutMs }
    let ms = (seconds * 1000).rounded()
    guard ms >= 1 else { return defaultBatchTimeoutMs }
    return ms < Double(Int64.max) ? Int64(ms) : .max
}

/// Buffers events, runs the `beforeSend` and `enrichEvent` hooks, and ships batches on size, on a
/// timer, or on demand.
final class EventsPool: LifecyclePool {
    private let config: ConfigManager
    private let session: SessionState
    private let transporter: Transporter
    private let deviceAttributes: () throws -> [String: Any]

    /// Types that never trigger a size flush; they ride along with the next one.
    private let eventsToSkipFlush: Set<String>

    private let executor: CoreExecutor
    private var events: [RumEvent] = []
    private var timer: ScheduledWork?
    private var initialized = false
    private var noClusterWarned = false
    private var beforeEnqueue: ((RumEvent) -> Void)?
    private var flushGate: (() -> Bool)?

    init(
        config: ConfigManager,
        session: SessionState,
        transporter: Transporter,
        deviceAttributes: @escaping () throws -> [String: Any],
        eventsToSkipFlush: Set<String>,
        executor: CoreExecutor
    ) {
        self.config = config
        self.session = session
        self.transporter = transporter
        self.deviceAttributes = deviceAttributes
        self.eventsToSkipFlush = eventsToSkipFlush
        self.executor = executor
    }

    func initialize() {
        if initialized { return }
        initialized = true
        if !events.isEmpty { scheduleFlush() }
    }

    func destroy() {
        timer?.cancel()
        timer = nil
        events = []
        initialized = false
    }

    func setBeforeEnqueueHook(_ hook: ((RumEvent) -> Void)?) {
        beforeEnqueue = hook
    }

    func setFlushGate(_ gate: (() -> Bool)?) {
        flushGate = gate
    }

    /// Drops the buffer without sending: a rotating session that never saw a user must neither ship
    /// its events nor leak them into the next session.
    func discardBuffer() {
        events = []
    }

    func earliestEventTimestamp(nowNs: Int64, maxAgeNs: Int64) -> Int64? {
        earliestTrustedEventTime(events, nowNs: nowNs, maxAgeNs: maxAgeNs)
    }

    private var isFlushAllowed: Bool { flushGate?() ?? true }

    func addEvent(_ event: RumEvent?) {
        guard let event, initialized else { return }
        let options = config.config.options
        var outgoing = event
        do {
            if let beforeSend = options.beforeSend {
                guard try UserHook.run({ try beforeSend(outgoing) }) else { return }
            }
            // A throwing hook drops the event: nothing is enqueued, and nothing reconciles for an
            // event that was never accepted.
            if let enrichEvent = options.enrichEvent {
                let enriched = outgoing
                outgoing = try UserHook.run { try enrichEvent(enriched) }
            }
        } catch {
            handleError(error)
            return
        }
        // What a hook put in is the app's own: made JSON data now, so the batch never fails on it.
        if options.beforeSend != nil || options.enrichEvent != nil {
            outgoing.attributes = toJsonMap(outgoing.attributes)
        }

        // After both hooks, still before enqueue: the observer drives session reconciliation, and a
        // rotation takes the new session's start from this event, so it must see the event as it
        // will ship (an enrichEvent may have moved its timestamp).
        beforeEnqueue?(outgoing)

        // After the observer, so an event that just opened the gate is not capped.
        if (!isFlushAllowed || config.config.cluster.isEmpty)
            && events.count >= maxGatedBufferEvents
        {
            return
        }
        events.append(outgoing)
        if events.count >= resolveBatchSize(options.transport.batchSize),
            !eventsToSkipFlush.contains(outgoing.type)
        {
            flush()
        }
        // The timer runs only while something waits to go: the first event after a send arms it.
        if initialized, !events.isEmpty, timer == nil { scheduleFlush() }
    }

    func flush() {
        guard initialized else { return }
        // Nothing to send: no timer until the next event, so an idle app isn't woken every window.
        guard !events.isEmpty else {
            cancelFlushTimer()
            return
        }
        // Held (no presence yet): keep the buffer and the timer.
        guard isFlushAllowed else {
            scheduleFlush()
            return
        }
        guard !config.config.cluster.isEmpty else {
            // The cluster can arrive by updateConfig, so keep the timer; say so once.
            if !noClusterWarned {
                noClusterWarned = true
                RumDiagnostics.shared.log("[events-pool.flush] skipping flush: no cluster")
            }
            scheduleFlush()
            return
        }
        noClusterWarned = false
        sendBuffer()
        cancelFlushTimer()
    }

    /// Sends the buffer now, before a session id is replaced. An unconfirmed session's events are
    /// discarded instead: they must not survive the id change.
    func flushSync() {
        guard initialized, !events.isEmpty else { return }
        guard isFlushAllowed else {
            discardBuffer()
            return
        }
        guard !config.config.cluster.isEmpty else {
            RumDiagnostics.shared.log("[events-pool.flush] skipping flush: no cluster")
            return
        }
        sendBuffer()
    }

    // The buffer is cleared before the send, so an event added while it is handed over waits for
    // the next batch instead of being lost.
    private func sendBuffer() {
        let batch = Batch(sessionAttributes: sessionAttributes(), events: events.map(\.wireJson))
        events = []
        transporter.send(batch)
    }

    private func cancelFlushTimer() {
        timer?.cancel()
        timer = nil
    }

    private func scheduleFlush() {
        timer?.cancel()
        let timeout = resolveBatchTimeoutMs(config.config.options.transport.batchTimeout)
        timer = executor.schedule(afterMs: timeout) { [weak self] in
            self?.timer = nil
            self?.flush()
        }
    }

    /// The envelope a batch sent now would carry.
    func sessionAttributes() -> [String: Any] {
        let config = config.config
        // Only the platform's part can fail, and only it is worth losing.
        var attributes: [String: Any] = [:]
        do {
            attributes = try deviceAttributes()
        } catch {
            handleError(error)
        }
        // Set after the device's, so a provider can never shadow session identity.
        attributes["cluster"] = config.cluster
        attributes["env"] = config.environment
        attributes["namespace"] = config.namespace
        attributes["releaseId"] = config.releaseId ?? ""
        attributes["session_id"] = session.sessionId
        attributes["session_start_time"] = session.sessionStartTimeNs
        attributes["user"] = userJson(config.user)
        attributes["service.name"] = config.appId
        return attributes
    }
}

/// The identity as the session envelope carries it: only the fields set.
func userJson(_ user: RumUser?) -> [String: Any] {
    guard let user else { return [:] }
    var json: [String: Any] = [:]
    if let id = user.id { json["id"] = id }
    if let email = user.email { json["email"] = email }
    if let name = user.name { json["name"] = name }
    if let role = user.role { json["role"] = role }
    if let organization = user.organization { json["organization"] = organization }
    if let properties = user.properties { json["properties"] = properties }
    return json
}
