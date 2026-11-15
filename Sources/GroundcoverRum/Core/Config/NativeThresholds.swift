import Foundation

// The defaults and clamps for NativeOptions. A value out of range falls back to the default rather
// than reaching the engine, where a nonsense threshold would arm a watchdog that fires constantly
// or never.

/// The main-thread stall before an app hang is reported: 2 s, a common default, since iOS has no
/// system hang bar of its own.
let defaultHangThresholdMs: Int64 = 2_000

/// The longest a frame-vitals segment runs before it is closed anyway. A safety valve, not a
/// cadence: segments normally end on a screen change or on backgrounding.
let defaultVitalsMaxSegmentMs: Int64 = 60_000

private let hangThresholdRangeMs: ClosedRange<Double> = 250...60_000
private let vitalsMaxSegmentRangeMs: ClosedRange<Double> = 1_000...300_000

/// `seconds` as whole milliseconds, rounded as the other SDKs round them, or `fallback` when it is
/// missing or out of `range`.
private func milliseconds(
    _ seconds: TimeInterval?, within range: ClosedRange<Double>, or fallback: Int64
) -> Int64 {
    guard let seconds, seconds.isFinite else { return fallback }
    let ms = (seconds * 1000).rounded()
    return range.contains(ms) ? Int64(ms) : fallback
}

/// ``NativeOptions/hangThreshold``, in milliseconds.
func resolveHangThresholdMs(_ seconds: TimeInterval?) -> Int64 {
    milliseconds(seconds, within: hangThresholdRangeMs, or: defaultHangThresholdMs)
}

/// ``NativeOptions/vitalsMaxSegment``, in milliseconds.
func resolveVitalsMaxSegmentMs(_ seconds: TimeInterval?) -> Int64 {
    milliseconds(seconds, within: vitalsMaxSegmentRangeMs, or: defaultVitalsMaxSegmentMs)
}
