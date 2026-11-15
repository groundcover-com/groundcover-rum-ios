/// What the lifecycle drives in the events pool.
protocol LifecyclePool: AnyObject {
    /// Runs before each event joins the buffer.
    func setBeforeEnqueueHook(_ hook: ((RumEvent) -> Void)?)

    /// Holds every send while it returns false.
    func setFlushGate(_ gate: (() -> Bool)?)

    func flush()
    func discardBuffer()

    /// The earliest trusted time among the buffered events.
    func earliestEventTimestamp(nowNs: Int64, maxAgeNs: Int64) -> Int64?
}

/// The session lifecycle policy: reconciliation (gap and cap expiry), rotation, the ghost-session
/// send gate, and the enqueue hook that drives them from events. Presence signals belong to the
/// platform and arrive through ``reconcile(nowMs:userPresent:triggeringEvent:)``; what they mean is
/// decided here. Lazy by design: a dormant app produces no signals, so nothing here runs.
final class SessionLifecycle {
    private let session: SessionState
    private let pool: LifecyclePool
    private let ids: IdGenerator
    private let clock: RumClock

    /// Which event types prove a human is present.
    private let activityEventTypes: Set<String>

    /// Heartbeat-style types that never drive reconciliation.
    private let ignoredEventTypes: Set<String>

    private(set) var isRotating = false

    init(
        session: SessionState,
        pool: LifecyclePool,
        idGenerator: IdGenerator,
        clock: @escaping RumClock,
        activityEventTypes: Set<String>,
        ignoredEventTypes: Set<String>
    ) {
        self.session = session
        self.pool = pool
        self.ids = idGenerator
        self.clock = clock
        self.activityEventTypes = activityEventTypes
        self.ignoredEventTypes = ignoredEventTypes
    }

    /// Arms the enqueue hook and the send gate, before any capture arms, so the gate is in place
    /// before the first event.
    func install() {
        pool.setBeforeEnqueueHook { [weak self] event in self?.reconcileOnEnqueue(event) }
        let session = session
        pool.setFlushGate { session.hasUserActivity }
    }

    /// The hook clears first (a teardown enqueue must not rotate), then the host's teardown runs,
    /// and the gate clears last, so an unconfirmed session's final batch stays held.
    func uninstall(hostTeardown: (() -> Void)? = nil) {
        pool.setBeforeEnqueueHook(nil)
        hostTeardown?()
        pool.setFlushGate(nil)
    }

    /// The reconciliation core, shared by every presence source, in order: expiry checks (an
    /// inactivity gap only for presence, then the cap for any signal), then presence stamps the
    /// activity clock and confirms the session, after the checks so it can't erase a gap it just
    /// found.
    ///
    /// `triggeringEvent` is the event that drove this, when there is one; a rotation starts the new
    /// session from it rather than from a second clock read.
    func reconcile(nowMs: Int64, userPresent: Bool, triggeringEvent: RumEvent? = nil) {
        if isRotating { return }
        if userPresent && session.isSessionInactive(nowMs: nowMs) {
            rotate(reason: "inactivity gap", triggeringEvent: triggeringEvent)
        }
        // After a gap rotation the start is fresh, so this can't rotate twice.
        let elapsedMs = session.sessionElapsedMs(nowMs: nowMs)
        let maxMs = session.sessionMaxDurationMs
        RumDiagnostics.shared.log(
            "[session-lifecycle] session reconcile",
            detail: ["userPresent": userPresent, "elapsedMs": elapsedMs, "maxDurationMs": maxMs])
        if elapsedMs >= maxMs {
            rotate(reason: "max session duration", triggeringEvent: triggeringEvent)
        }
        if userPresent { session.recordActivity(atMs: nowMs) }
    }

    private func reconcileOnEnqueue(_ event: RumEvent) {
        if isRotating || ignoredEventTypes.contains(event.type) { return }
        reconcile(
            nowMs: clock(), userPresent: activityEventTypes.contains(event.type),
            triggeringEvent: event)
    }

    /// Rotates only when the session is stale, before an operation that must run under a current
    /// one.
    func rotateIfStale(nowMs: Int64, reason: String) {
        if session.isSessionInactive(nowMs: nowMs) || session.isSessionExpired(nowMs: nowMs) {
            rotate(reason: reason)
        }
    }

    /// The single rotation primitive. A confirmed session flushes its stragglers under the old id;
    /// an unconfirmed (ghost) session's buffer is discarded, so it can't leak into the new id.
    func rotate(reason: String, triggeringEvent: RumEvent? = nil) {
        if isRotating { return }
        isRotating = true
        defer { isRotating = false }

        let previousId = session.sessionId
        // Before the id flip, which resets it.
        let wasConfirmed = session.hasUserActivity
        RumDiagnostics.shared.log(
            "[session-lifecycle] session rotation start",
            detail: ["reason": reason, "previousId": previousId, "wasConfirmed": wasConfirmed])
        if wasConfirmed {
            pool.flush()
        } else {
            pool.discardBuffer()
        }

        let newId = ids.generateId()
        // Resolved before either write, so the new id is never paired with the old start.
        let startNs = resolveNewSessionStartTime(triggeringEvent)
        session.sessionId = newId
        session.setSessionStartTime(startNs)
        session.clearSamplingDecision()
        RumDiagnostics.shared.log(
            "[session-lifecycle] session id rotated", detail: ["from": previousId, "to": newId])
    }

    // A session must never start after an event that belongs to it: consumers derive its duration
    // from last event - session_start_time. So the start is the earliest trusted time among the
    // clock, the triggering event (not in the pool yet), and whatever the flush left in the pool.
    // Candidates are trusted only within the tighter of the cap and the idle window, so a bogus-old
    // time can't open a session that is born already stale.
    private func resolveNewSessionStartTime(_ triggeringEvent: RumEvent?) -> Int64 {
        let nowNs = msToNs(clock())
        let maxAgeNs = msToNs(min(session.sessionMaxDurationMs, sessionInactivityTimeoutMs))
        var earliest = nowNs
        for candidate in [
            earliestTrustedEventTime([triggeringEvent], nowNs: nowNs, maxAgeNs: maxAgeNs),
            pool.earliestEventTimestamp(nowNs: nowNs, maxAgeNs: maxAgeNs),
        ] {
            if let candidate, isTrustedEventTime(candidate, nowNs: nowNs, maxAgeNs: maxAgeNs),
                candidate < earliest
            {
                earliest = candidate
            }
        }
        return earliest
    }
}
