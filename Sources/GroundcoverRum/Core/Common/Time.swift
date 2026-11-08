import Foundation

/// The SDK's clock: epoch milliseconds. Injected wherever a time is read, so tests run on a fixed
/// one.
typealias RumClock = () -> Int64

func systemClock() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
}

let msToNanoseconds: Int64 = 1_000_000

/// Epoch milliseconds to nanoseconds, the wire's unit, as exact 64-bit integers: a double steps in
/// 256 ns near 1.8e18.
func msToNs(_ ms: Int64) -> Int64 { ms * msToNanoseconds }

/// Nanoseconds back to milliseconds, the fraction dropped.
func nsToMs(_ ns: Int64) -> Int64 { ns / msToNanoseconds }

/// ``msToNs(_:)`` for a time with a fractional part, as the engine reports some. The whole
/// milliseconds convert exactly; only the fraction goes through a double, so the result is off by
/// under a nanosecond rather than by the 256 ns a double steps in at today's epoch.
func fractionalMsToNs(_ ms: Double) -> Int64 {
    let whole = ms.rounded(.down)
    return msToNs(Int64(whole)) + Int64(((ms - whole) * Double(msToNanoseconds)).rounded())
}
