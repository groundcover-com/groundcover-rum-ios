import Foundation

/// The judgement half of the hang watchdog.
///
/// `GCRumHangWatchdog` is a thread, a run-loop timer and two UIKit
/// notifications, none of which a unit test can drive, so the decision it makes
/// at the end of a stall lives here instead.
/// This is the same split every other engine unit makes
/// (`GCRumFrameAggregator`, `GCRumGestureClassifier`, `GCRumAppStartRules`):
/// the judgement moves somewhere a test can reach it, the plumbing stays behind.
enum GCRumHangRules {
    /// How often the main thread beats. Fixed and short: a stall is measured from the last beat
    /// before it, so this interval (plus the timer's tolerance) is how early a stall can appear to
    /// start, and how long a shorter one can read.
    static let heartbeatInterval: TimeInterval = 0.1

    /// How often the monitor thread looks at the heartbeat while waiting for a stall, for a
    /// threshold: a fifth of it, between 0.1 s and 1 s. It wakes its thread every interval for the
    /// app's whole foreground life, so at the default 2 s threshold that is 2.5 wakeups a second
    /// rather than ten. It only decides how soon a stall is noticed: waiting for one to end goes at
    /// the heartbeat's interval, which is what keeps the duration as precise as the heartbeat.
    static func monitorInterval(thresholdMs: Double) -> TimeInterval {
        min(max(thresholdMs / 5 / 1000, 0.1), 1.0)
    }

    /// How long to report for a stall that has just ended, or `nil` when there
    /// is nothing to report.
    ///
    /// - Parameters:
    ///   - startedAt: when the stall began — the last heartbeat before it.
    ///   - lastBeat: the heartbeat as of now. It only advances when the main
    ///     thread actually ran something, so it IS the recovery signal.
    ///   - stopped: the watchdog is being torn down.
    static func recoveredDurationMs(
        startedAt: TimeInterval,
        lastBeat: TimeInterval,
        stopped: Bool
    ) -> Double? {
        guard !stopped else { return nil }
        // The heartbeat must have MOVED. The monitor's wait loop also breaks
        // when the app is backgrounded, and a suspended app is not a hung one —
        // its beat is still the pre-stall one, so reporting on it would emit
        // "Main thread blocked for 0ms" every time a user sent a stalling app
        // away. `>` rather than `!=` also covers a wall-clock correction moving
        // the beat backwards mid-stall, which would otherwise be a negative
        // duration that `max(0, …)` downstream renders as the same phantom zero.
        guard lastBeat > startedAt else { return nil }
        return (lastBeat - startedAt) * 1000
    }
}
