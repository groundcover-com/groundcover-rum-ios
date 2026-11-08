let defaultSessionMaxDurationMs: Int64 = 4 * 60 * 60 * 1000
let minSessionMaxDurationMs: Int64 = 60 * 1000
let maxSessionMaxDurationMs: Int64 = 8 * 60 * 60 * 1000

/// One idle window, two consumers: the lazy gap check rotates the session when user activity
/// resumes after a gap this long, and idle policies key off it.
let sessionInactivityTimeoutMs: Int64 = 30 * 60 * 1000

/// The activity clock is stamped on every user interaction and persisted at most this often. The
/// gap check runs at 30-minute resolution, so a value up to a minute stale across a restart is
/// harmless.
let activityPersistThrottleMs: Int64 = 60 * 1000

let defaultSessionSampleRate = 1.0
let defaultBatchSize = 10
let defaultBatchTimeoutMs: Int64 = 10_000
let defaultCompression = true
