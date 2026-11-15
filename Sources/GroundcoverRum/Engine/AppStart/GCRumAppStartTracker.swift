import Foundation
#if canImport(UIKit)
import UIKit
#endif
// The load-time anchors are Objective-C (GCRumProcessBoot). CocoaPods compiles
// them into this module, where their header needs no import. A Swift package
// cannot mix the two languages in one target, so the Flutter plugin builds them
// as a target of their own, and that module has to be imported.
#if canImport(GroundcoverRumBoot)
import GroundcoverRumBoot
#endif

/// Reports how long the app took to become visible.
///
/// The cold-start anchors are NOT measured here — under React Native and Flutter,
/// by the time this exists the framework has initialized and launch is long over.
/// They are stamped at load time by GCRumProcessBoot.m, and this reads them. What
/// this owns is the interpretation (which anchor applies, is the value sane) and HOT
/// starts — foreground returns — which happen while the engine is alive. The native
/// SDKs start the engine inside `didFinishLaunching`, before the first frame, so a
/// drain can also come before the anchor it reads: it then waits for that frame.
final class GCRumAppStartTracker {
    /// Which anchor applies and whether the number is believable lives in
    /// [GCRumAppStartRules], where it is unit-tested. What is left here is the
    /// UIKit half: reading the load-time anchors, waiting for a frame, and
    /// buffering a launch measured before anyone was listening.
    typealias AppStart = GCRumAppStart

    private var pending: [AppStart] = []
    private var foregroundedAtMs: Double?
    private let lock = NSLock()

    /// Whether THIS PROCESS has already reported its cold start.
    ///
    /// Static, because the fact it records is a property of the process rather than of a tracker:
    /// the anchors live in `GCRumProcessBoot.m`'s process-globals and are never cleared, so a
    /// tracker built after `stop()` — every Metro fast-refresh reload — reads a first-frame
    /// timestamp that is still set and reports the same launch again. Android's twin is a
    /// process-static `object` whose `reset()` deliberately leaves this flag alone.
    private static var reportedColdStart = false
    private static let coldStartLock = NSLock()

    /// How many starts may queue before a handler exists. A cold start plus a hot one per
    /// foreground, and only while nobody is draining — which is the whole life of a process that
    /// never enables `appStart`. Bounded so that never-drained case cannot grow without limit;
    /// OLDEST-wins, because the cold start arrives first and is the one worth keeping.
    private static let maxPending = 16

    private var warmFrameLink: CADisplayLink?
    /// Whether a drain is waiting for the launch's first frame, and whether `stop()` ended that.
    /// Under `lock`: the wait starts on main, `stop()` comes from the engine's thread.
    private var awaitingFirstFrame = false
    private var stopped = false
    private var onAppStart: ((AppStart) -> Void)?
    private let observers = GCRumNotificationObservers()

    init() {
        observeLifecycle()
    }

    deinit {
        warmFrameLink?.invalidate()
        observers.removeAll()
    }

    func stop() {
        warmFrameLink?.invalidate()
        warmFrameLink = nil
        lock.lock()
        stopped = true
        lock.unlock()
        observers.removeAll()
    }

    /// Hands over the cold start measured before anyone was listening, then
    /// keeps streaming hot starts.
    func drain(into handler: @escaping (AppStart) -> Void) {
        reportColdStartIfReady()

        lock.lock()
        let buffered = pending
        pending = []
        onAppStart = handler
        lock.unlock()

        buffered.forEach(handler)
        awaitFirstFrameIfNeeded()
    }

    private static var coldStartReported: Bool {
        coldStartLock.lock()
        defer { coldStartLock.unlock() }
        return reportedColdStart
    }

    private func reportColdStartIfReady() {
        Self.coldStartLock.lock()
        let alreadyReported = Self.reportedColdStart
        Self.coldStartLock.unlock()
        guard !alreadyReported else { return }

        let firstFrameMs = GCRumFirstFrameEpochMs()
        // Not drawn yet (a launch still in flight, or a headless start). Nothing
        // to report; the next drain picks it up.
        guard firstFrameMs > 0 else { return }

        // Validate BEFORE claiming the launch as reported. Setting the flag first would let a
        // `sysctl` failure in `GCRumProcessStartEpochMs()` — or any anchor the rules reject — burn
        // it while producing nothing, and no later `drain()` would retry: the launch would be lost
        // permanently rather than for one attempt.
        guard let start = GCRumAppStartRules.coldStart(
            prewarmed: GCRumWasPrewarmed(),
            processStartMs: GCRumProcessStartEpochMs(),
            moduleLoadMs: GCRumModuleLoadEpochMs(),
            firstFrameMs: firstFrameMs,
            backgroundedBeforeFirstFrame: GCRumBackgroundedBeforeFirstFrame()
        ) else { return }

        // Claim it and report, under one acquisition: two drains racing here would otherwise both
        // pass the guard above and report the same launch twice.
        Self.coldStartLock.lock()
        let won = !Self.reportedColdStart
        Self.reportedColdStart = true
        Self.coldStartLock.unlock()
        guard won else { return }

        report(start)
    }

    private func report(_ start: AppStart) {
        lock.lock()
        let handler = onAppStart
        // Dropped rather than evicting the oldest: the cold start is the first thing in here and
        // the most valuable, so a buffer that is somehow full must not lose it to hot starts.
        if handler == nil && pending.count < Self.maxPending { pending.append(start) }
        lock.unlock()

        handler?(start)
    }

    /// A drain before the launch's first frame (the native SDKs start the engine during
    /// `didFinishLaunching`) reports the cold start once that frame is drawn, instead of waiting
    /// for a next drain that never comes.
    ///
    /// Armed whenever the cold start is still unreported, never on a fresh read of the anchor:
    /// main can stamp it between the drain's read and this one, and then neither would report.
    /// The load-time observer calls back as it stamps the frame, or at once if it already has.
    private func awaitFirstFrameIfNeeded() {
        #if canImport(UIKit)
        guard !Self.coldStartReported else { return }
        GCRumMainThread.run { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let arm = !self.stopped && !self.awaitingFirstFrame
            if arm { self.awaitingFirstFrame = true }
            self.lock.unlock()
            guard arm else { return }
            GCRumOnFirstFrame { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let report = !self.stopped
                self.awaitingFirstFrame = false
                self.lock.unlock()
                if report { self.reportColdStartIfReady() }
            }
        }
        #endif
    }

    // MARK: - Hot starts (foreground returns)

    private func observeLifecycle() {
        #if canImport(UIKit)
        observers.observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            // A scene-based app is told it enters the foreground as its launching scene appears,
            // before the launch's first frame. That is the cold start, not a return: a return
            // always comes after the launch has drawn.
            guard let self, GCRumFirstFrameEpochMs() > 0 else { return }
            self.lock.lock()
            self.foregroundedAtMs = Date().timeIntervalSince1970 * 1000
            self.lock.unlock()
            self.awaitWarmFrame()
        }
        #endif
    }

    /// Coming back from the background is its own start, measured the same way: from the
    /// transition to the next frame the user actually sees. Reported as HOT, not warm — the UI was
    /// never torn down, and Android reserves `warm` for the case where it was.
    private func awaitWarmFrame() {
        #if canImport(UIKit)
        // The notification that triggers this already arrives on main, but hop
        // anyway: a CADisplayLink added to the main run loop from another thread
        // may never fire, and a hot start would then simply never be reported.
        GCRumMainThread.run { [weak self] in
            guard let self, self.warmFrameLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.handleWarmFrame))
            link.add(to: .main, forMode: .common)
            self.warmFrameLink = link
        }
        #endif
    }

    @objc private func handleWarmFrame() {
        warmFrameLink?.invalidate()
        warmFrameLink = nil

        lock.lock()
        let anchor = foregroundedAtMs
        foregroundedAtMs = nil
        lock.unlock()

        guard let anchor,
              let start = GCRumAppStartRules.hotStart(
                  foregroundedAtMs: anchor,
                  firstFrameMs: Date().timeIntervalSince1970 * 1000
              ) else { return }
        report(start)
    }
}
