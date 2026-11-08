import Foundation

// The events the engine's signals become.

/// The `performance` event for `start`, with a fresh metric id. Stamped when it is sent, as RN's:
/// it describes the launch, which has no single moment of its own.
func shapeAppStartEvent(_ start: AppStartCapture, metricId: String) -> EnrichInput {
    EnrichInput(
        type: "performance",
        attributes: [
            "performance_metric_name": start.metric.rawValue,
            "performance_metric_value": start.valueMs,
            "performance_metric_id": metricId,
            "performance_metric_navigation_type": start.navigationType,
        ])
}

/// Two decimals: whole milliseconds would round one marginally slow frame's delay (0.28 ms at
/// 60 Hz) down to a smooth screen's zero.
private func twoDecimals(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

/// The `performance` event for `segment`, one `frames_delay_total`, with a fresh metric id. No
/// frame count and no rate: platforms don't count the same frames.
func shapeFrameSegmentEvent(_ segment: FrameSegmentCapture, metricId: String) -> EnrichInput {
    var attributes: [String: Any] = [
        "performance_metric_name": "frames_delay_total",
        "performance_metric_value": twoDecimals(segment.delayMs),
        "performance_metric_id": metricId,
        // Launch context means nothing for a steady-state metric; the screen stamp attributes it.
        "performance_metric_navigation_type": "",
        "performance_refresh_rate_hz": segment.refreshRate,
        "performance_segment_reason": segment.reason.rawValue,
        // Nanoseconds, as navigation events ship under these names, so a segment intersects the
        // navigations around it with no conversion.
        "start_timestamp": msToNs(segment.startMs),
        "end_timestamp": msToNs(segment.endMs),
        // Absolute counts, which a consumer sums across segments.
        "performance_frames_slow": segment.slow,
        "performance_frames_frozen": segment.frozen,
    ]
    if segment.budgetMs.isFinite, segment.budgetMs > 0 {
        attributes["performance_frame_budget_ms"] = twoDecimals(segment.budgetMs)
    }
    // The segment's end, not now: it describes a past interval, and stamping it when sent would
    // place a screen's jank after the navigation that ended it.
    return EnrichInput(
        type: "performance", attributes: attributes, timestamp: msToNs(segment.endMs))
}

/// The longest duration a hang reports, so rounding a broken one can't overflow.
private let maxHangDurationMs = Double(Int64.max / 2)

/// Groups by duration bucket, not exact milliseconds; otherwise every hang is its own issue and the
/// pattern (this screen freezes for about 5 s) never surfaces.
private func durationBucket(_ ms: Int64) -> String {
    if ms < 1_000 { return "<1s" }
    if ms >= 30_000 { return "30s+" }
    return "\(ms / 1_000)s"
}

/// The `exception` event for `hang`. A frozen app is an error the user experienced, so a hang is
/// one, not a type of its own: it lands in the same view, under the same fingerprint rules.
func shapeHangEvent(_ hang: HangCapture) -> EnrichInput {
    let durationMs = Int64(min(max(hang.durationMs, 0), maxHangDurationMs).rounded())
    let type = hang.kind.wireName
    return EnrichInput(
        type: "exception",
        attributes: [
            "error_type": type,
            "error_message": "Main thread blocked for \(durationMs)ms",
            "error_stacktrace": hang.frames.map(\.json),
            "error_fingerprint": "\(type):\(durationBucket(durationMs))",
            // The user couldn't use the app: nobody handled it.
            "error_handled": false,
            "error_metadata": [
                "native": true,
                "hang_duration_ms": durationMs,
                "hang_started_at": hang.startedAtMs,
                // Tells it apart from the post-mortem ANR record, a stall the process never came
                // back from.
                "recovered": true,
            ] as [String: Any],
        ],
        // When the stall began, not now: it is reported only on recovery, after the taps and
        // navigations it blocked.
        timestamp: fractionalMsToNs(hang.startedAtMs))
}
