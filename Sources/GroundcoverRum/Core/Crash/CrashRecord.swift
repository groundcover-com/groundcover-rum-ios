import Foundation

/// A crash record as the engine filed it, coerced at the trust boundary: the JSON comes off the
/// device's disk, possibly written by another SDK version. Coerced, never dropped, apart from the
/// ack key: each fallback is what the drain uses for an absent field.
struct CrashRecord {
    /// The ack key, stable across redeliveries, so a duplicate can be recognised.
    var id: String

    /// When it crashed, or nil when the record lost it (the event then takes the time it is sent).
    var crashEpochMs: Double?
    var errorType = ""
    var errorMessage = ""
    var frames: [ErrorFrame] = []
    var metadata: [String: Any] = [:]

    /// The session the engine filed it under.
    var sessionSnapshotJson: String?

    /// The crash-time screen, when the engine could read one.
    var screen: (name: String, key: String)?
}

/// The cause chain a record may carry, above the producers' own cap (Kotlin's 5; iOS writes none):
/// a resource guard against a corrupt record, not a restatement of their contract.
private let maxCauseEntries = 20

/// The latest crash time the wire's nanoseconds hold, in milliseconds: early in 2262.
private let maxCrashEpochMs = Double(Int64.max / msToNanoseconds)

/// When it crashed, or nil for no usable time: the engine writes 0 when the crash report had none,
/// and a time in the wrong unit, or corrupt, would overflow the wire's nanoseconds.
func crashTime(_ value: Any?) -> Double? {
    guard let ms = finiteNumber(value), ms > 0, ms < maxCrashEpochMs else { return nil }
    return ms
}

/// A frame's line or column, or nil past what one can be.
private func lineNumber(_ value: Any?) -> Int? {
    guard let number = finiteNumber(value), number >= 0, number <= Double(Int32.max) else {
        return nil
    }
    return Int(number)
}

/// The records in the engine's JSON array. Only one without an id is dropped: it could never be
/// acked, so it would be redelivered forever.
func parseCrashRecords(_ json: String) -> [CrashRecord] {
    guard let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
        return []
    }
    return decoded.compactMap { raw in
        guard let raw = raw as? [String: Any], let id = raw["id"] as? String, !id.isEmpty else {
            return nil
        }
        return CrashRecord(
            id: id,
            crashEpochMs: crashTime(raw["crashEpochMs"]),
            errorType: raw["errorType"] as? String ?? "",
            errorMessage: raw["errorMessage"] as? String ?? "",
            frames: stackFrames(of: raw["stacktrace"]),
            metadata: (raw["metadata"] as? [String: Any]).map(cappingCauses) ?? [:],
            sessionSnapshotJson: raw["sessionSnapshotJson"] as? String,
            screen: crashScreen(of: raw["screen"]))
    }
}

private func cappingCauses(_ metadata: [String: Any]) -> [String: Any] {
    guard let causes = metadata["causes"] as? [Any], causes.count > maxCauseEntries else {
        return metadata
    }
    var capped = metadata
    capped["causes"] = Array(causes.prefix(maxCauseEntries))
    return capped
}

/// Both members strings, and not the engines' "couldn't read one" sentinel (`{name: "", key: ""}`),
/// so the snapshot's screen still applies then.
func crashScreen(of value: Any?) -> (name: String, key: String)? {
    guard let value = value as? [String: Any], let name = value["name"] as? String,
        let key = value["key"] as? String, !(name.isEmpty && key.isEmpty)
    else { return nil }
    return (name, key)
}

/// `value` when it is a finite JSON number. Never a numeric string, nor a Bool: the engine writes
/// numbers, so anything else means its contract already broke.
func finiteNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let double = number.doubleValue
    return double.isFinite ? double : nil
}

/// RN's normalizeStackFrames: a frame without a filename symbolicates to nothing and is dropped;
/// the other fields fall back to their documented values (no symbol is `""`; a native frame's
/// line is 0).
func stackFrames(of frames: Any?) -> [ErrorFrame] {
    guard let frames = frames as? [Any] else { return [] }
    return frames.compactMap { frame in
        guard let frame = frame as? [String: Any], let filename = frame["filename"] as? String
        else { return nil }
        return ErrorFrame(
            filename: filename,
            function: frame["function"] as? String ?? "",
            lineno: lineNumber(frame["lineno"]) ?? 0,
            colno: lineNumber(frame["colno"]) ?? 0)
    }
}
