import Foundation

// The engine's signals as captures. A signal that breaks the contract is dropped rather than
// repaired: a payload that lost a field is no measurement, and a zero-filled one would assert
// something that never happened.

/// The capture a `kind` signal's `payload` carries, or nil for one that carries none (`ping` marks
/// the engine live; `app_start` goes to the app-start tracker, see ``appStartOfSignal(_:)``) or one
/// that breaks the contract.
func captureOfSignal(_ kind: String, _ payload: [String: Any]) -> Capture? {
    switch kind {
    case "hang":
        // An epoch time nanoseconds can hold, as a crash's must be.
        guard let startedAtMs = crashTime(payload["startedAtMs"]),
            let durationMs = finiteNumber(payload["durationMs"])
        else { return nil }
        return .hang(
            HangCapture(
                kind: payload["kind"] as? String == "anr" ? .anr : .appHang,
                startedAtMs: startedAtMs, durationMs: durationMs,
                frames: stackFrames(of: payload["mainThreadStack"])))
    default:
        return nil
    }
}

/// A count the engine reports, within what a frame count can be.
private func frameCount(_ value: Any?) -> Int? {
    guard let count = finiteNumber(value), count >= 0, count <= Double(Int32.max) else {
        return nil
    }
    return Int(count)
}

/// The segment a `frame_segment` payload closes, drawn on the screen `screenName` and `screenKey`
/// name, unless it breaks the contract. A missing budget is no budget; a missing delay is no
/// measurement, and a reason outside the three is a payload from another engine.
func frameSegmentOf(_ payload: [String: Any], screenName: String, screenKey: String)
    -> FrameSegmentCapture?
{
    guard let startMs = crashTime(payload["segmentStartMs"]),
        let endMs = crashTime(payload["segmentEndMs"]),
        let total = frameCount(payload["total"]), let slow = frameCount(payload["slow"]),
        let frozen = frameCount(payload["frozen"]),
        let refreshRate = finiteNumber(payload["refreshRate"]),
        let delayMs = finiteNumber(payload["delayMs"]), delayMs >= 0,
        let reason = (payload["reason"] as? String).flatMap(FrameSegmentReason.init(rawValue:))
    else { return nil }
    return FrameSegmentCapture(
        startMs: Int64(startMs.rounded()), endMs: Int64(endMs.rounded()), total: total,
        slow: slow, frozen: frozen, refreshRate: refreshRate, delayMs: delayMs,
        budgetMs: finiteNumber(payload["budgetMs"]) ?? 0, reason: reason, screenName: screenName,
        screenKey: screenKey)
}

/// The launch an `app_start` signal's `payload` reports, unless it breaks the contract. Both
/// anchors are epoch times nanoseconds can hold, as a crash's must be: TTI is measured from the
/// start, and a time outside that range would overflow its conversion.
func appStartOfSignal(_ payload: [String: Any]) -> AppStartSignal? {
    guard let type = payload["type"] as? String, let startMs = crashTime(payload["startMs"]),
        let firstFrameMs = crashTime(payload["firstFrameMs"])
    else { return nil }
    return AppStartSignal(type: type, startMs: startMs, firstFrameMs: firstFrameMs)
}
