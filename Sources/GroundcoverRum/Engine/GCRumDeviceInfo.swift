import Foundation

/// Device facts iOS does not hand to React Native.
///
/// RN's iOS `Platform.constants` carries no hardware model — forceTouchAvailable, interfaceIdiom,
/// isTesting, osVersion, reactNativeVersion, systemName, and nothing more — while its Android
/// counterpart carries `Model`. Without this, `device.model` would be `"unknown"` on iOS.
/// The identifier here (`"iPhone17,1"`) is what `uname()` reports; it is deliberately NOT mapped to
/// a marketing name ("iPhone 16 Pro"), which needs a lookup table that is stale the day a device
/// ships.
enum GCRumDeviceInfo {
    /// The hardware model identifier, or `""` when it cannot be determined.
    ///
    /// Empty rather than a sentinel on purpose: `"unknown"` is the WIRE's answer for an absent
    /// model and belongs to the one place that owns that contract, which is JavaScript. Two owners
    /// of one sentinel is how a literal `"unknown"` ends up looking like a real device.
    static func hardwareModel() -> String {
        return hardwareModel(
            simulatorIdentifier: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
            machine: unameMachine()
        )
    }

    /// The decision, separated from the two lookups so it is testable off a real device.
    static func hardwareModel(simulatorIdentifier: String?, machine: String) -> String {
        // A simulator reports the HOST's architecture in utsname.machine — "arm64" — which is not a
        // device model and is worse on the wire than nothing: it collapses every simulator and
        // every Apple-silicon Mac into one value that reads as real. The simulated device's own
        // identifier is in the environment instead, which is also why a simulator without it
        // reports "unknown" rather than a wrong-but-present value.
        let simulated = simulatorIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !simulated.isEmpty { return simulated }
        return machine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `utsname.machine` as a Swift string, or `""` if the syscall fails.
    static func unameMachine() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        // `machine` is a fixed-size CChar tuple, so it has to be rebound rather than read as a
        // Swift value; `String(cString:)` then stops at the NUL the kernel wrote. Rebind with the
        // tuple's FULL element count, not 1: `String(cString:)` scans to the NUL, so a capacity of
        // 1 lets it read past the single valid element — undefined behavior that trips the bounds
        // checker and sanitizers even though it usually returns the right string.
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}
