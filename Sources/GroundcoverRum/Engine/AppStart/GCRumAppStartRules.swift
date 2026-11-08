import Foundation

/// One measured launch.
struct GCRumAppStart: Equatable {
    let type: String
    /// Per-type anchor. Cold measures from process start; hot from the
    /// foreground transition — a hot start hours into a live process must not
    /// be measured from when the process began.
    let startMs: Double
    let firstFrameMs: Double

    var durationMs: Double { firstFrameMs - startMs }
}

/// Which anchor a launch is measured from, and whether the result is believable.
///
/// Kept apart from [GCRumAppStartTracker] because this is the part that produces
/// nonsense when it is wrong — a prewarmed process that began minutes before
/// the user tapped the icon, a device that slept mid-launch — and nonsense here
/// does not crash anything. It quietly poisons the metric with durations no
/// user ever experienced.
enum GCRumAppStartRules {
    /// Beyond this a "launch" is not a launch: the device slept, the app was
    /// suspended mid-start, a debugger was attached.
    static let sanityCapMs: Double = 60_000

    /// Builds a cold start from the anchors stamped at load time.
    ///
    /// - Parameters:
    ///   - prewarmed: the system started the process ahead of the user's tap.
    ///   - processStartMs: kernel process start.
    ///   - moduleLoadMs: when our load-time constructor ran.
    ///   - firstFrameMs: when the first frame was drawn; 0 if not drawn yet.
    ///   - backgroundedBeforeFirstFrame: the app was in the background before that frame.
    /// - Returns: the launch, or nil when there is nothing believable to report.
    static func coldStart(
        prewarmed: Bool,
        processStartMs: Double,
        moduleLoadMs: Double,
        firstFrameMs: Double,
        backgroundedBeforeFirstFrame: Bool = false
    ) -> GCRumAppStart? {
        // Not drawn yet — a launch still in flight, or a headless start.
        guard firstFrameMs > 0 else { return nil }

        // Launched in the background, or sent there mid-launch: process start to first frame is
        // no launch anyone waited through, and nothing marks where the user's own open began, so
        // there is no cold start to report.
        // Asked of the app's state, not of a time window: a foreground launch that is merely slow
        // to draw is the one most worth reporting.
        guard !backgroundedBeforeFirstFrame else { return nil }

        // A prewarmed process may have started minutes before the user tapped
        // the icon, so module load — not process start — is when the launch the
        // user perceives began.
        let anchor = prewarmed ? moduleLoadMs : processStartMs
        return validated(
            type: prewarmed ? "cold_prewarmed" : "cold",
            startMs: anchor,
            firstFrameMs: firstFrameMs
        )
    }

    /// Coming back from the background is its own start, measured from the
    /// transition to the next frame the user actually sees.
    /// A return to the foreground with the UI still intact — a HOT start.
    ///
    /// Named for what the platform can actually observe. `willEnterForegroundNotification` fires on
    /// every foreground return, including the common case where nothing was torn down, while
    /// Android reports warm only when the Activity was genuinely recreated. Calling these `warm`
    /// would count a different population from Android's, and a cross-OS comparison would read a
    /// definitional difference as a performance gap.
    ///
    /// So iOS emits no `warm` start: this notification can't tell a scene or window rebuild apart,
    /// and inventing one would leave two platforms disagreeing about what a label means. An absent
    /// series is honest; a wrong one is not.
    static func hotStart(foregroundedAtMs: Double, firstFrameMs: Double) -> GCRumAppStart? {
        validated(type: "hot", startMs: foregroundedAtMs, firstFrameMs: firstFrameMs)
    }

    private static func validated(
        type: String,
        startMs: Double,
        firstFrameMs: Double
    ) -> GCRumAppStart? {
        // A missing anchor reads as epoch zero, which would report a launch that
        // took 56 years. An end before its start is a clock that moved.
        guard startMs > 0, firstFrameMs >= startMs else { return nil }
        guard firstFrameMs - startMs <= sanityCapMs else { return nil }
        return GCRumAppStart(type: type, startMs: startMs, firstFrameMs: firstFrameMs)
    }
}
