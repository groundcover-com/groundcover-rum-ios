import Foundation

/// Accumulates frame durations into ONE open segment and hands it back when something
/// closes it. Per SCREEN, not per interval: no timer here, because a fixed wall-clock window
/// straddling a navigation would be labelled with whichever screen was current when it closed.
///
/// A pure value transformer — `record` and `flush` RETURN the closed segment rather than
/// invoking a callback, so it is testable without a display. Same shape as Android's
/// `GcRumFrameAggregator`, so the two platforms agree on what "slow" means.
final class GCRumFrameAggregator {
    /// A frame this late is not slow, it is a freeze — the user perceives the
    /// app as hanging rather than stuttering.
    static let frozenThresholdMs: Double = 700

    /// A "frame" longer than this is not jank — it is the process being SUSPENDED (backgrounded,
    /// device asleep), after which CADisplayLink resumes with one enormous delta that would add the
    /// whole suspension to a segment as phantom "lost time". Well above any real freeze the
    /// app survives, and real long stalls arrive via `recordHang` (not capped here), so excluding
    /// these cannot hide a hang. iOS-only: Android's FrameMetrics fires on real draws, so it never
    /// produces a suspend-gap frame.
    static let suspendGapThresholdMs: Double = 10_000

    /// How late a frame must be to count as slow: one frame interval plus a vsync's
    /// tolerance. `1000 / (rate - 1)` rather than `1000 / rate`, so a frame landing a hair
    /// after its deadline — which every frame does — is not called slow. Relative to the
    /// display, since a fixed 16.7ms bar would call a stuttering 120Hz app healthy.
    static func slowThresholdMs(refreshRateHz: Double) -> Double {
        // A 1Hz display does not exist, but the subtraction below divides by zero
        // there and the guard costs nothing.
        guard refreshRateHz > 1 else { return 1000.0 / refreshRateHz }
        return 1000.0 / (refreshRateHz - 1)
    }

    /// The slow bar from a frame's expected interval directly, for adaptive-refresh displays where
    /// the interval varies frame to frame. Identical to `slowThresholdMs(refreshRateHz:)` at a fixed
    /// rate — it just enters from the interval the display was actually running rather than a nominal
    /// rate, so a ProMotion panel resting at 60Hz is judged at 60Hz, not its 120Hz peak.
    static func slowThresholdMs(expectedFrameMs: Double) -> Double {
        guard expectedFrameMs > 0 else { return slowThresholdMs(refreshRateHz: 60) }
        return slowThresholdMs(refreshRateHz: 1000.0 / expectedFrameMs)
    }

    /// One frame's worth of time — the budget a frame is late relative to.
    ///
    /// Distinct from `slowThresholdMs` on purpose: that bar is deliberately one vsync's tolerance
    /// looser, so a frame a hair past its deadline is not CALLED slow. Once a frame is slow, though,
    /// the time the user lost is everything past the budget, not past the bar.
    static func expectedFrameMs(refreshRateHz: Double) -> Double {
        return refreshRateHz > 0 ? 1000.0 / refreshRateHz : 1000.0 / 60.0
    }

    /// Why a segment ended. Ships on the wire, so a consumer can sum consecutive
    /// `safety` segments up to a `navigation`/`background` one and recover a
    /// whole screen's total.
    ///
    /// The raw values ARE the wire strings — they are mirrored by a TypeScript
    /// union, and nothing off-device compares the two.
    enum SegmentReason: String {
        /// The user navigated. JavaScript asked for this one, because only
        /// JavaScript knows the screen is about to change.
        case navigation
        /// The app left the foreground. Pushed by native — the screen has not
        /// changed, so the ambient stamp is correct.
        case background
        /// The segment simply ran too long. A screen has no upper bound on how
        /// long a user stays, and unflushed counters are data nobody can see.
        case safety
    }

    struct Segment {
        let startMs: Double
        let endMs: Double
        let total: Int
        let slow: Int
        let frozen: Int
        let refreshRate: Double
        /// Milliseconds lost across every slow frame — each one's duration beyond the frame budget,
        /// summed. An ABSOLUTE duration on purpose: a rate needs a denominator, and the two
        /// platforms do not count the same frames, so no rate is reported. Idle frames add exactly
        /// zero here.
        let delayMs: Double
        /// The budget `slow` and `delayMs` were actually judged against, in milliseconds.
        ///
        /// Ships because ``refreshRate`` alone does NOT let a consumer reproduce them: on an
        /// adaptive panel this is the ESTIMATED cadence, which on an idle 120Hz display is ~16.7ms
        /// against a nominal 8.33ms — a factor of two. Anyone recomputing our arithmetic from the
        /// wire without it gets a different answer and nothing to explain the difference.
        let budgetMs: Double
        let reason: SegmentReason
    }

    /// How many recent frame intervals feed the cadence estimate — ~0.25s at 60Hz. Long enough to
    /// be a stable baseline, short enough to track a genuine rate change within a few frames.
    private static let cadenceWindow = 15

    private let maxSegmentMs: Double
    private let refreshRateHz: Double

    /// Optional rather than a 0 sentinel: 0 is a perfectly valid timestamp, and
    /// a sentinel that collides with a real value silently swallows the first
    /// segment instead of opening it.
    private var segmentStartMs: Double?
    private var total = 0
    private var slow = 0
    private var frozen = 0
    private var delayMs: Double = 0

    /// The last few OBSERVED frame intervals, used to estimate the rate the display is ACTUALLY
    /// running at. Deliberately NOT reset with the segment counters: cadence is a property of the
    /// display, not of one screen's dwell, so it survives `close`/`reset` and only warms up once
    /// per process. See `budgetMs`.
    private var recentDurations: [Double] = []

    init(maxSegmentMs: Double, refreshRateHz: Double) {
        self.maxSegmentMs = maxSegmentMs
        // A zero or negative rate would make every frame infinitely slow.
        self.refreshRateHz = refreshRateHz > 0 ? refreshRateHz : 60
    }

    /// Adds a frame to the open segment.
    ///
    /// Each frame is judged against the interval the display is ACTUALLY running at, estimated from
    /// the recent OBSERVED frame durations — not the panel's peak. This matters on ProMotion:
    /// `CADisplayLink.targetTimestamp − timestamp` reports the 120Hz peak (8.33ms) even while an
    /// idle panel presents at 60Hz, so judging a normal 16.7ms frame against 8.33ms would mark
    /// nearly every idle frame slow. The observed
    /// cadence is authoritative — a frame is late only when it overruns what the display has been
    /// delivering, so a steady low idle rate reads healthy while an OUTLIER stands out.
    ///
    /// The tradeoff, taken deliberately: uniformly-sustained jank (every frame equally late) drifts
    /// into the baseline and reads healthy — but that is rare, an adaptive display legitimately
    /// choosing a low steady rate is NOT jank, and the frozen-frame / hang detectors still catch
    /// the severe end.
    ///
    /// - Returns: the closed segment when this frame pushed the segment past `maxSegmentMs`,
    ///   otherwise nil. A segment normally ends via `flush`.
    /// - Parameters:
    ///   - frameDurationMs: how long this frame took end to end.
    ///   - nowMs: wall clock, passed in so tests need no real time.
    @discardableResult
    func record(frameDurationMs: Double, nowMs: Double) -> Segment? {
        // A suspension/sleep gap is not a frame the user waited on — drop it so elapsed background
        // time never lands in the jank counters. It does not open or advance a segment.
        guard frameDurationMs <= Self.suspendGapThresholdMs else { return nil }

        let startMs = segmentStartMs ?? nowMs
        segmentStartMs = startMs

        let budgetMs = budgetMs()

        total += 1
        if frameDurationMs > Self.slowThresholdMs(expectedFrameMs: budgetMs) {
            slow += 1
            // Measured against the frame BUDGET, not the slow bar — see `expectedFrameMs`.
            delayMs += frameDurationMs - budgetMs
        }
        if frameDurationMs > Self.frozenThresholdMs { frozen += 1 }

        // Fold this frame into the cadence estimate AFTER judging it, so a frame is compared to its
        // history rather than to itself. Outliers (a stall) enter too, but the median absorbs an
        // isolated one; a sustained rate change settles the baseline within the window.
        recentDurations.append(frameDurationMs)
        if recentDurations.count > Self.cadenceWindow { recentDurations.removeFirst() }

        // The cap is checked AFTER counting, so the frame that closes a segment
        // belongs to the segment it closes rather than to the next one.
        guard nowMs - startMs >= maxSegmentMs else { return nil }
        return close(endMs: nowMs, reason: .safety)
    }

    /// Adds a HANG the frame sampler could not see as a synthetic frozen frame, so hangs are
    /// counted in `frames_frozen`. On iOS the `CADisplayLink` sampler runs on the main thread — the
    /// exact thread a hang blocks — so a stall produces a GAP, not a long frame, and the hang is
    /// invisible to the frame counters (Android gets this for free: FrameMetrics charges an
    /// in-frame stall to the frame's `TOTAL_DURATION`). The hang watchdog, on its own thread,
    /// catches every hang and feeds it here so the two detectors agree.
    ///
    /// - Note: the caller resets the sampler's frame clock after this so the natural giant
    ///   recovery-gap frame is not ALSO counted (see GCRumFrameTracker).
    @discardableResult
    func recordHang(durationMs: Double, nowMs: Double) -> Segment? {
        guard durationMs > 0 else { return nil }
        let startMs = segmentStartMs ?? nowMs
        segmentStartMs = startMs

        let budgetMs = budgetMs()
        total += 1
        slow += 1
        frozen += 1
        delayMs += max(0, durationMs - budgetMs)

        guard nowMs - startMs >= maxSegmentMs else { return nil }
        return close(endMs: nowMs, reason: .safety)
    }

    /// One frame's budget — the interval a frame is late relative to.
    ///
    /// On a FIXED-rate display (≤60Hz — most iPhones, and every Android in lockstep) the panel
    /// always targets its nominal interval, so a sustained low rate genuinely IS jank there: the
    /// budget is the nominal interval. Cadence estimation is ONLY for adaptive (ProMotion)
    /// panels, whose idle rate legitimately drops below the peak — there the budget is the median of
    /// the recently observed intervals (the rate the display is actually running at), so a normal
    /// idle 16.7ms frame on a 120Hz-nominal panel is not charged against the 8.33ms peak. With no
    /// history yet (the first frame of the process) even an adaptive panel falls back to the nominal
    /// peak, so a genuinely slow first frame is still caught — at most one warm-up frame per
    /// process, since the window survives segment closes.
    private func budgetMs() -> Double {
        let nominal = Self.expectedFrameMs(refreshRateHz: refreshRateHz)
        guard refreshRateHz > 60, !recentDurations.isEmpty else { return nominal }
        let sorted = recentDurations.sorted()
        return sorted[sorted.count / 2]
    }

    /// Closes the open segment and hands it over.
    ///
    /// - Returns: nil when no frames were recorded — an empty segment is not
    ///   news, and emitting one would make "0 frames" indistinguishable from
    ///   "0% slow".
    func flush(endMs: Double, reason: SegmentReason) -> Segment? {
        guard total > 0 else { return nil }
        return close(endMs: endMs, reason: reason)
    }

    /// Drops the in-flight segment without reporting — used when returning from
    /// the background, where the gap is not a real frame time.
    ///
    /// Re-anchors as well as clearing: the time spent backgrounded must not count
    /// toward the safety cap, or the first frame back would immediately close a
    /// segment containing that one frame.
    func reset(nowMs: Double) {
        segmentStartMs = nowMs
        total = 0
        slow = 0
        frozen = 0
        delayMs = 0
    }

    /// Builds the segment and reopens the next one at the same instant, so
    /// coverage is contiguous — a gap here is frames measured and then dropped,
    /// which is worse than not measuring them because the totals look complete.
    private func close(endMs: Double, reason: SegmentReason) -> Segment {
        let segment = Segment(
            startMs: segmentStartMs ?? endMs,
            endMs: endMs,
            total: total,
            slow: slow,
            frozen: frozen,
            refreshRate: refreshRateHz,
            delayMs: delayMs,
            // Sampled at CLOSE. On an adaptive panel the estimate moves frame to frame, and the
            // settled value is the one that judged all but the warm-up frames; the cadence window
            // deliberately survives a close, so it is stable across a segment boundary.
            budgetMs: budgetMs(),
            reason: reason
        )
        reset(nowMs: endMs)
        return segment
    }
}
