import Foundation

/// Everything the engine needs to run, decoded from the JSON the bridge hands it.
///
/// Note what is NOT here: the DSN and the API key. Native captures and persists;
/// JavaScript enriches and transports. The one piece of session state native
/// holds is the snapshot, which it needs on disk to attribute a crash after the
/// JS runtime is gone.
///
/// Decoding treats every key as OPTIONAL, falling back to the documented default —
/// the same contract `GcRumEngineConfig.kt` has through `optJSONObject` /
/// `optBoolean` / `optLong`.
///
/// Why not strict: a missing section could disarm capture rather than arm it
/// "half-configured with whatever a default would have been". But the fallbacks are
/// not a guess — they are the SDK's own documented defaults, the very values the host
/// sends when it configures nothing. So the choice is never
/// "off versus half-configured", it is "off versus exactly the default", and off is
/// the worse end: `nativeInit` resolves a decode failure to an all-off status that
/// reads identically to "the host asked for nothing", so a bundle that predates a key
/// a newer binary requires would silently take native capture down with no way to
/// tell. A hang threshold at its default is a mild inaccuracy; no crash reporting is
/// a blind app.
struct GCRumEngineConfig: Decodable {
    struct Features: Decodable {
        var crashes = false
        var hangs = false
        var appStart = false
        var vitals = false
        var gestures = false

        private enum CodingKeys: String, CodingKey {
            case crashes, hangs, appStart, vitals, gestures
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A bare `try? decode(Bool.self)` is NOT `optBoolean(key, false)`. `org.json` coerces
            // the strings "true"/"false", so without the same coercion `"hangs": "true"` would arm
            // hangs on Android and not on iOS. Coerced here so the two agree; anything that is
            // neither a bool nor one of those strings is false on both.
            func flag(_ key: CodingKeys) -> Bool {
                if let value = try? container.decode(Bool.self, forKey: key) { return value }
                if let text = try? container.decode(String.self, forKey: key) {
                    return text.lowercased() == "true"
                }
                return false
            }
            crashes = flag(.crashes)
            hangs = flag(.hangs)
            appStart = flag(.appStart)
            vitals = flag(.vitals)
            gestures = flag(.gestures)
        }
    }

    struct Thresholds: Decodable {
        /// The SDK's iOS hang default — 2 s, a common default. The host sends the same value
        /// when it configures nothing; the two change together.
        ///
        /// NOT `GcRumEngineConfig.kt`'s 5_000: the platforms differ here on purpose,
        /// because Android tolerates a longer stall before calling it a hang
        /// (`DEFAULT_ANDROID_HANG_THRESHOLD_MS`). Copying the Kotlin fallback over here
        /// to "match the twin" would quietly move iOS from 2s to 5s.
        static let defaultHangThresholdMs: Double = 2_000
        /// The SDK's segment cap; this one IS the same on both platforms.
        static let defaultVitalsMaxSegmentMs: Double = 60_000

        var hangThresholdMs = Self.defaultHangThresholdMs
        /// Safety valve, not a cadence — a frame segment normally ends on a
        /// navigation or on backgrounding.
        var vitalsMaxSegmentMs = Self.defaultVitalsMaxSegmentMs

        private enum CodingKeys: String, CodingKey {
            case hangThresholdMs, vitalsMaxSegmentMs
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Numeric strings coerce, because `optLong` accepts them and the two
            // platforms have to read one config the same way. Non-finite and
            // non-positive fall back rather than arming: a hang threshold of 0 or -1
            // reports every frame as a hang, and `1e400` decodes to `.infinity` here
            // while `optLong` would saturate — so neither is a value to honour.
            func threshold(_ key: CodingKeys, or fallback: Double) -> Double {
                let raw = (try? container.decode(Double.self, forKey: key))
                    ?? (try? container.decode(String.self, forKey: key)).flatMap(Double.init)
                guard let value = raw, value.isFinite else { return fallback }
                // Truncated, because `optLong` truncates: 2500.7 is 2500 on Android, so it
                // is 2500 here too, and the two platforms read one config the same way. The
                // magnitude is irrelevant; the divergence would not be.
                let whole = value.rounded(.towardZero)
                // AFTER truncating, so 0.5 falls back rather than arming a 0ms threshold.
                guard whole > 0 else { return fallback }
                return whole
            }
            hangThresholdMs = threshold(.hangThresholdMs, or: Self.defaultHangThresholdMs)
            vitalsMaxSegmentMs = threshold(.vitalsMaxSegmentMs, or: Self.defaultVitalsMaxSegmentMs)
        }
    }

    let features: Features
    let thresholds: Thresholds
    let snapshotJson: String?
    /// Clear the stored envelope at the END of `GCRumEngine.start`, after the crash harvest that
    /// reads it. The unsampled path needs exactly that pair — harvest what a previous SAMPLED run
    /// left, then leave nothing for a crash in THIS run to be attributed to.
    ///
    /// A flag rather than "an explicit JSON null in ``snapshotJson``", because a serializer that
    /// omits null-valued keys turns that signal into "leave the previous envelope alone" —
    /// silently, and in the direction of misattribution.
    ///
    /// Optional so a JS bundle that predates the field still decodes: `Decodable`'s synthesised
    /// init fails on a missing key for a non-optional property, and a bundle older than the binary
    /// is the ordinary OTA case, not an error.
    let clearSnapshotAfterHarvest: Bool?

    private enum CodingKeys: String, CodingKey {
        case features, thresholds, snapshotJson, clearSnapshotAfterHarvest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = (try? container.decode(Features.self, forKey: .features)) ?? Features()
        thresholds = (try? container.decode(Thresholds.self, forKey: .thresholds)) ?? Thresholds()
        // Strict on TYPE, unlike the two blocks above, and Kotlin is as strict: `optString`
        // coerces a number to its own text, so a loose read would turn `"snapshotJson": 42`
        // into the envelope `"42"` — a snapshot that parses nowhere and attributes a crash
        // to nothing. Absent, null and any non-string all mean "no snapshot" on both
        // platforms.
        snapshotJson = try? container.decode(String.self, forKey: .snapshotJson)
        // `try?` rather than `decodeIfPresent`, for the reason the property's own doc gives:
        // a bundle older than this binary sends no such key, and that is the ordinary OTA
        // case rather than an error. nil therefore means "not asked for", which
        // `GCRumEngine.start` reads as false — the only safe default, since clearing on a
        // SAMPLED launch would make every crash in that session unattributable. Mirrors the
        // Kotlin twin's `optBoolean("clearSnapshotAfterHarvest", false)`.
        clearSnapshotAfterHarvest = try? container.decode(Bool.self, forKey: .clearSnapshotAfterHarvest)
    }

    /// Still throws, and deliberately: input that is not JSON at all carries no keys to
    /// fall back on, so there is nothing to be lenient about. Leniency is per-key.
    static func decode(from json: String) throws -> GCRumEngineConfig {
        guard let data = json.data(using: .utf8) else {
            throw GCRumEngineError.malformedConfig
        }
        return try JSONDecoder().decode(GCRumEngineConfig.self, from: data)
    }
}

/// Which features actually armed. Reported back through `nativeInit` so the JS
/// side never suppresses its own capture in favour of a tracker that failed to
/// attach.
struct GCRumEngineStatus: Encodable {
    var crashes = false
    var hangs = false
    var appStart = false
    var vitals = false
    var gestures = false

    /// Whether the gesture tracker is hooked to a window at the moment this status is reported —
    /// not merely that it was created, which is what ``gestures`` says.
    ///
    /// Only ever true for a re-init: on a first `start` the attach is still queued on the main
    /// queue, and the tracker's own `gestures_attached` signal reports it. That signal is
    /// edge-triggered though, and a second `start` returns early without re-attaching, so the edge
    /// cannot be replayed for a JavaScript context that arrived after it — which is every Metro
    /// fast-refresh. Left unreported, JS would suppress nothing while the tracker kept measuring,
    /// and each gesture would be reported twice with disagreeing kinematics.
    var gesturesAttached = false

    /// Whether that tracker reaches EVERY surface the app can present — see
    /// ``GCRumGestureTracker/coversAllSurfaces``, true here because attachment is per `UIWindow`
    /// and a `Modal` renders into one.
    ///
    /// Carried on the status for the same reason `gesturesAttached` is: a re-init never sees the
    /// `gestures_attached` signal that also carries it, so this is the only way a fresh JavaScript
    /// context learns what the running tracker can actually see. Without it a reloaded context
    /// would assume no modal coverage and report every modal drag twice.
    var gesturesCoverAllSurfaces = false

    /// Why crash reporting is not running, when the host asked for it and we
    /// could not oblige — in practice, another KSCrash-based reporter already
    /// owns the process-wide singleton.
    ///
    /// `crashes: false` alone cannot say this: it reads identically to "the host
    /// never asked". The engine holds no logger by design, so it reports the
    /// reason and JavaScript warns. Encoded only when set — presence IS the
    /// signal, so a key that was always there would need null-checking at every
    /// reader.
    var crashesUnavailable: String?

    init() {}

    func encodedJson() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

enum GCRumEngineError: Error {
    case malformedConfig
}
