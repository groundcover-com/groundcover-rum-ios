// Reading an event's own occurrence time back off the event. Only top-level fields count, and
// both must be read: a network event has a `startTimestamp` and no `timestamp`, every other event
// the reverse. Attributes are off limits: a navigation's `start_timestamp` there is when the screen
// it left became current, which can predate the session, and an app's own attributes carry times
// in any unit.

/// Whether `value` is a time to trust: inside (nowNs - maxAgeNs, nowNs].
///
/// The window is what makes deriving session identity from event data safe. Legitimate backdating
/// is small (a rotation stamped from a second clock read, an in-flight network span); everything
/// untrustworthy is off by orders of magnitude (milliseconds where nanoseconds belong reads as
/// 1970, and 0 means unset). Both bounds come from the same clock read as `nowNs`, so a uniformly
/// wrong device clock shifts them together. The lower bound is strict: at exactly one idle window
/// back the inactivity check already reads stale.
func isTrustedEventTime(_ value: Int64?, nowNs: Int64, maxAgeNs: Int64) -> Bool {
    guard let value else { return false }
    return value > 0 && value <= nowNs && value > nowNs - maxAgeNs
}

/// The earliest trusted occurrence time across `events`, or nil.
func earliestTrustedEventTime(_ events: [RumEvent?], nowNs: Int64, maxAgeNs: Int64) -> Int64? {
    var earliest: Int64?
    for event in events {
        guard let event else { continue }
        for value in [event.timestamp, event.startTimestamp] {
            if let value, isTrustedEventTime(value, nowNs: nowNs, maxAgeNs: maxAgeNs),
                earliest.map({ value < $0 }) ?? true
            {
                earliest = value
            }
        }
    }
    return earliest
}
