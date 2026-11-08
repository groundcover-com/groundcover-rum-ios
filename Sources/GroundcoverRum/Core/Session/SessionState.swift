/// The persisted keys, shared with the Flutter, React Native and browser SDKs' storage, and with
/// the testing hooks.
enum SessionKeys {
    static let id = SessionStorage.idKey

    /// Nanoseconds since the epoch.
    static let startTime = SessionStorage.startTimeKey

    /// Milliseconds since the epoch.
    static let lastActivity = SessionStorage.lastActivityKey

    static let sampling = SessionStorage.samplingKey
}

/// Per-session identity and activity: the id, its start time, the activity clock, their
/// persistence, and the gap and cap rules over them.
final class SessionState {
    private let storage: SafeStorage
    private let maxDurationMs: (() -> Int64?)?
    private var cachedSessionId: String?
    private var cachedStartTimeNs: Int64?
    private var cachedLastActivityMs: Int64?
    private var lastPersistedActivityMs: Int64 = 0

    init(storage: SafeStorage, maxDurationMs: (() -> Int64?)? = nil) {
        self.storage = storage
        self.maxDurationMs = maxDurationMs
    }

    var sessionId: String {
        get { cachedSessionId ?? storage.getItem(SessionKeys.id) ?? "" }
        set {
            cachedSessionId = newValue
            storage.setItem(SessionKeys.id, newValue)
        }
    }

    /// Nanoseconds, or 0 when none is recorded.
    var sessionStartTimeNs: Int64 {
        if let cachedStartTimeNs, cachedStartTimeNs != 0 { return cachedStartTimeNs }
        return storage.getIntegerItem(SessionKeys.startTime)
    }

    /// Starts the session at `startTimeNs`. A session is born unconfirmed: the activity clock is
    /// cleared, in memory and in storage, so a restart cannot read a stale value and confirm it
    /// falsely.
    func setSessionStartTime(_ startTimeNs: Int64) {
        cachedStartTimeNs = startTimeNs
        storage.setItem(SessionKeys.startTime, String(startTimeNs))
        cachedLastActivityMs = nil
        lastPersistedActivityMs = 0
        storage.removeItem(SessionKeys.lastActivity)
    }

    /// The last genuine activity, epoch milliseconds; 0 when none this session.
    var lastActivityMs: Int64 {
        cachedLastActivityMs ?? storage.getIntegerItem(SessionKeys.lastActivity)
    }

    /// On every user interaction: exact in memory, throttled to storage.
    func recordActivity(atMs nowMs: Int64) {
        cachedLastActivityMs = nowMs
        if nowMs - lastPersistedActivityMs >= activityPersistThrottleMs {
            persistLastActivity()
        }
    }

    /// Writes the exact activity clock, for the background path, so a restart does not read a value
    /// a throttle window stale.
    func persistLastActivity() {
        guard let last = cachedLastActivityMs else { return }
        lastPersistedActivityMs = last
        storage.setItem(SessionKeys.lastActivity, String(last))
    }

    /// The inactivity rule. Before any activity the gap is measured from birth.
    func isSessionInactive(nowMs: Int64) -> Bool {
        let last = lastActivityMs
        let baseline = last > 0 ? last : nsToMs(sessionStartTimeNs)
        return baseline > 0 && nowMs - baseline >= sessionInactivityTimeoutMs
    }

    /// Whether the session has seen genuine interaction: the ghost-session send gate. A stamped
    /// activity clock is the confirmation.
    var hasUserActivity: Bool { lastActivityMs > 0 }

    /// Drops the persisted sampling verdict, so the next session re-rolls it.
    func clearSamplingDecision() {
        storage.removeItem(SessionKeys.sampling)
    }

    /// Clears every session key and its in-memory mirror.
    func clearSessionState() {
        cachedSessionId = nil
        cachedStartTimeNs = nil
        cachedLastActivityMs = nil
        lastPersistedActivityMs = 0
        storage.removeItem(SessionKeys.id)
        storage.removeItem(SessionKeys.startTime)
        storage.removeItem(SessionKeys.lastActivity)
        clearSamplingDecision()
    }

    var sessionMaxDurationMs: Int64 { maxDurationMs?() ?? defaultSessionMaxDurationMs }

    /// Milliseconds since the session started; 0 without a recorded start.
    func sessionElapsedMs(nowMs: Int64) -> Int64 {
        let startNs = sessionStartTimeNs
        return startNs != 0 ? nowMs - nsToMs(startNs) : 0
    }

    /// The cap rule. False without a recorded start.
    func isSessionExpired(nowMs: Int64) -> Bool {
        sessionElapsedMs(nowMs: nowMs) >= sessionMaxDurationMs
    }
}
