/// Session-level sampling: decided once per session and persisted, so a restart mid-session keeps
/// its verdict. A rate of 1 (or nil) samples everything; an explicit 0 samples nothing.
func resolveSamplingDecision(
    storage: SafeStorage,
    sessionSampleRate: Double?,
    random: () -> Double = { Double.random(in: 0..<1) }
) -> Bool {
    guard let rate = sessionSampleRate, rate.isFinite, rate != 1 else { return true }
    if let stored = storage.getItem(SessionKeys.sampling), !stored.isEmpty {
        let decision = stored == "1"
        RumDiagnostics.shared.log(
            "[session-bootstrap] using stored sampling decision:", detail: decision)
        return decision
    }
    let decision = random() < rate
    storage.setItem(SessionKeys.sampling, decision ? "1" : "0")
    RumDiagnostics.shared.log("[session-bootstrap] stored new sampling decision:", detail: decision)
    return decision
}

private let futureSkewToleranceMs: Int64 = 60_000

/// Start-time session identity, resolved before the lifecycle arms, so the first event carries a
/// current id.
///
/// 1. A new provided id starts its own cap clock; the same id provided again is a continuation that
///    keeps the stored start. No id at all mints one.
/// 2. A persisted start is trusted only if positive and not implausibly in the future (a minute
///    absorbs clock skew). Otherwise it is treated as missing.
/// 3. Expiry at start mirrors the per-event check: a restart is activity too.
func bootstrapSession(
    session: SessionState,
    idGenerator: IdGenerator,
    clock: RumClock,
    providedSessionId: String?
) {
    let existing = session.sessionId
    if let provided = providedSessionId, !provided.isEmpty, provided != existing {
        session.sessionId = provided
        session.setSessionStartTime(msToNs(clock()))
        // A different session: its sampling verdict is re-rolled.
        session.clearSamplingDecision()
        RumDiagnostics.shared.log("[session-bootstrap] using provided sessionId:", detail: provided)
    } else if let provided = providedSessionId, !provided.isEmpty {
        session.sessionId = provided
        RumDiagnostics.shared.log(
            "[session-bootstrap] continuing provided sessionId:", detail: provided)
    } else if existing.isEmpty {
        session.sessionId = idGenerator.generateId()
    }

    let nowMs = clock()
    let persistedStartMs = nsToMs(session.sessionStartTimeNs)
    let hasValidStart = persistedStartMs > 0 && nowMs - persistedStartMs >= -futureSkewToleranceMs
    if !hasValidStart {
        session.setSessionStartTime(msToNs(nowMs))
    } else if session.isSessionExpired(nowMs: nowMs) || session.isSessionInactive(nowMs: nowMs) {
        let reason =
            session.isSessionExpired(nowMs: nowMs)
            ? "persisted session past cap" : "inactivity gap across restart"
        let previousId = session.sessionId
        let newId = idGenerator.generateId()
        session.sessionId = newId
        session.setSessionStartTime(msToNs(nowMs))
        session.clearSamplingDecision()
        RumDiagnostics.shared.log(
            "[session-bootstrap] start-time rotation: \(reason)",
            detail: ["from": previousId, "to": newId])
    }
}
