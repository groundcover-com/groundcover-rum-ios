import Foundation

/// The native engine, as the pipeline drives it: crashes, hangs, app start and frame vitals. Never
/// throws: a native failure degrades to nothing armed, never to an error in the app's launch.
protocol NativeEngine: AnyObject {
    /// Where the engine's signals go, by kind (`hang`, `app_start`, `frame_segment`, `ping`), on any
    /// thread. Set before ``start(configJson:completion:)``: the engine emits from inside it.
    var onSignal: ((String, [String: Any]) -> Void)? { get set }

    /// Starts the engine with `configJson` (see ``engineConfigJson(_:recording:snapshotJson:)``),
    /// off the caller's thread. `completion` gets what it armed, on any thread.
    func start(configJson: String, completion: @escaping (NativeEngineStatus) -> Void)

    /// Stops the watchdog and the trackers. The crash handler stays armed: a crash during teardown
    /// is still worth reporting.
    func stop()

    /// Closes the open frame segment, as a screen change does, and hands over its `frame_segment`
    /// payload, or nil when nothing is open; `completion` runs once, on any thread.
    func flushFrameSegment(completion: @escaping ([String: Any]?) -> Void)
}

/// What the engine armed.
struct NativeEngineStatus {
    var crashes = false
    var hangs = false
    var appStart = false
    var vitals = false

    /// Why crash capture isn't running when it was asked for: usually another reporter owning the
    /// process's crash handling.
    var crashesUnavailable: String?
}

/// The engine's config, as JSON.
///
/// `recording` is whether this session is sampled. Crash capture is armed either way, because it
/// governs delivery as well as capture: the harvest that turns the previous run's crash into a
/// pending record runs in the engine's crash block, so an unsampled launch must still run it, or a
/// crash from an earlier sampled session is never delivered. `clearSnapshotAfterHarvest` makes that
/// safe: an unsampled launch clears the previous run's envelope right after the harvest read it, so
/// a crash in this run has no session to be filed under.
///
/// `snapshotJson` is this session's envelope, which the engine installs right after its harvest
/// has read the previous run's, in the same step. A push couldn't promise that order.
///
/// Gestures stay off: the capture layer owns taps and gestures.
func engineConfigJson(_ options: ResolvedOptions, recording: Bool, snapshotJson: String?)
    -> String
{
    var config: [String: Any] = [
        "features": [
            "crashes": options.isEnabled(.crashes),
            "hangs": recording && options.isEnabled(.hangs),
            "appStart": recording && options.isEnabled(.appStart),
            "vitals": recording && options.isEnabled(.vitals),
            "gestures": false,
        ],
        "thresholds": [
            "hangThresholdMs": resolveHangThresholdMs(options.native?.hangThreshold),
            "vitalsMaxSegmentMs": resolveVitalsMaxSegmentMs(options.native?.vitalsMaxSegment),
        ],
        "clearSnapshotAfterHarvest": !recording,
    ]
    if let snapshotJson { config["snapshotJson"] = snapshotJson }
    return encodeJson(config)
}
