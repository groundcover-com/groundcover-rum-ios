import Foundation

// App start and time to interactive. The native engine measures how long the launch took to its
// first frame; the app adds the interactive mark, because only it knows when a screen is usable.

/// When the app became usable: the "I" in TTI. Process state rather than the pipeline's, as RN's
/// and the Flutter SDK's: a mark can come before start, and it records when it was called. Each is
/// set once, since the first screen a user reaches is the one TTI is about.
final class InteractiveMarks: @unchecked Sendable {
    static let shared = InteractiveMarks()

    private let lock = NSLock()
    private var autoMs: Int64?
    private var manualMs: Int64?

    /// The automatic anchor: the first screen landing. A floor rather than a promise: it comes
    /// before that screen's own data loads. Says whether this call set it.
    @discardableResult
    func markAuto(nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard autoMs == nil else { return false }
        autoMs = nowMs
        return true
    }

    /// The app's own word that the first screen is usable. Says whether this call set it.
    @discardableResult
    func markManual(nowMs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard manualMs == nil else { return false }
        manualMs = nowMs
        return true
    }

    /// The mark `manual` or automatic TTI is measured to, once it has landed.
    func mark(manual: Bool) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return manual ? manualMs : autoMs
    }

    /// The testing reset, whose next start begins afresh.
    func reset() {
        lock.lock()
        autoMs = nil
        manualMs = nil
        lock.unlock()
    }
}

/// One `app_start` signal from the engine, in epoch milliseconds.
struct AppStartSignal {
    var type: String
    var startMs: Double
    var firstFrameMs: Double
}

/// How long a launch metric waits for the screen it landed on: far more useful attributed to it,
/// but a screenless app must not lose the metric.
let appStartScreenWaitMs: Int64 = 5_000

/// Which metric each engine start type ships under, and whether it anchors TTI. Cold starts only:
/// TTI is measured from the cold start's origin, and a foreground return hours into the process is
/// no such origin. An unknown type is rejected rather than guessed, since the type picks the
/// series.
private let appStartTypes: [String: (metric: AppStartMetric, anchorsTti: Bool)] = [
    "cold": (.cold, true),
    "cold_prewarmed": (.cold, true),
    "warm": (.warm, false),
    "hot": (.hot, false),
]

/// Holds each launch metric for the first screen, and reports TTI once, from the cold start's
/// origin. Confined to the core queue.
final class AppStartTracker {
    private let submit: (Capture) -> Void
    private let manualTti: Bool
    private let marks: InteractiveMarks
    private let executor: CoreExecutor
    private let diagnostics: RumDiagnostics

    private var screenIsKnown = false
    private var waiting: [() -> Void] = []
    private var screenTimer: ScheduledWork?
    private var disposed = false

    /// The cold start's origin and value, which TTI is measured from and clamped to.
    private var coldStartMs: Double?
    private var coldDurationMs: Int64?

    /// Whether the cold start went out: TTI follows it, never precedes it, even when the mark lands
    /// while the cold start waits for its screen.
    private var coldSent = false
    private var reportedTti = false

    init(
        submit: @escaping (Capture) -> Void, manualTti: Bool, marks: InteractiveMarks,
        executor: CoreExecutor, diagnostics: RumDiagnostics
    ) {
        self.submit = submit
        self.manualTti = manualTti
        self.marks = marks
        self.executor = executor
        self.diagnostics = diagnostics
    }

    func onAppStart(_ start: AppStartSignal) {
        guard !disposed else { return }
        let elapsed = (start.firstFrameMs - start.startMs).rounded()
        guard elapsed >= 0, elapsed < Double(Int64.max) else { return }
        let durationMs = Int64(elapsed)
        guard let known = appStartTypes[start.type] else {
            diagnostics.log("[app-start] dropped an app start of unknown type \(start.type)")
            return
        }
        if known.anchorsTti {
            coldStartMs = start.startMs
            coldDurationMs = durationMs
        }
        whenScreenKnown { [weak self] in
            self?.submit(
                .appStart(
                    AppStartCapture(
                        metric: known.metric, valueMs: durationMs, navigationType: start.type)))
            // The mark may have landed while this waited for the screen.
            if known.anchorsTti { self?.coldSent = true }
            self?.reportTtiIfReady()
        }
    }

    /// A screen landed: launch metrics held for one go out under it.
    func screenKnown() {
        guard !screenIsKnown else { return }
        screenIsKnown = true
        screenTimer?.cancel()
        screenTimer = nil
        release()
    }

    /// TTI, once the cold start went out and the mark this mode waits for has landed, measured from
    /// the cold start's origin.
    func reportTtiIfReady() {
        guard !disposed, !reportedTti, coldSent, let startMs = coldStartMs,
            let coldMs = coldDurationMs, let markMs = marks.mark(manual: manualTti)
        else { return }
        reportedTti = true
        // Clamped to the first frame: an app holding a splash screen can mark itself interactive
        // before anything was visible.
        let ttiMs = Int64((Double(markMs) - startMs).rounded())
        submit(
            .appStart(
                AppStartCapture(metric: .tti, valueMs: max(ttiMs, coldMs), navigationType: "cold")))
    }

    func dispose() {
        disposed = true
        screenTimer?.cancel()
        screenTimer = nil
        waiting.removeAll()
    }

    private func whenScreenKnown(_ emit: @escaping () -> Void) {
        if screenIsKnown { return emit() }
        waiting.append(emit)
        if screenTimer == nil {
            screenTimer = executor.schedule(afterMs: appStartScreenWaitMs) { [weak self] in
                self?.screenTimer = nil
                self?.release()
            }
        }
    }

    private func release() {
        let released = waiting
        waiting.removeAll()
        for emit in released { emit() }
    }
}
