import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Counts frames the app failed to deliver on time. This half is only plumbing — a
/// CADisplayLink for the deltas, and the transitions that must not be counted as frames;
/// the judgement lives in [GCRumFrameAggregator], where it is testable without a screen.
/// The aggregator hands segments BACK, so what to do with a closed one is this type's job.
///
/// Only the OBSERVED interval between ticks is handed to the aggregator, which estimates the
/// display's actual running rate from those. The link's own `targetTimestamp − timestamp` is not
/// the per-frame budget: on an idle ProMotion panel it reports the 120Hz peak (8.33ms) even while
/// the panel presents at 60Hz, which would charge a normal 16.7ms frame as slow. The nominal peak
/// survives only as the reported `refreshRate`.
final class GCRumFrameTracker {
    typealias Segment = GCRumFrameAggregator.Segment
    typealias SegmentReason = GCRumFrameAggregator.SegmentReason

    private let maxSegmentMs: Double
    private let onSegment: (Segment) -> Void

    /// Built on the main thread in `start()`, because the refresh rate it needs
    /// comes from `UIScreen.main`.
    private var aggregator: GCRumFrameAggregator?

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private let observers = GCRumNotificationObservers()

    /// Whether `stop()` has already run. Main-thread-only, like everything else here — see `stop`.
    private var stopped = false

    init(maxSegmentMs: Double, onSegment: @escaping (Segment) -> Void) {
        self.maxSegmentMs = maxSegmentMs
        self.onSegment = onSegment
    }

    /// Everything here is main-thread-only API — `UIScreen.main`, and a
    /// CADisplayLink added to the main run loop, which may never fire if it was
    /// installed from another thread. The engine arms off-main, hence the hop.
    func start() {
        #if canImport(UIKit)
        GCRumMainThread.run { [weak self] in
            guard let self, self.displayLink == nil else { return }
            self.aggregator = GCRumFrameAggregator(
                maxSegmentMs: self.maxSegmentMs,
                refreshRateHz: Self.displayRefreshRateHz()
            )
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
            self.observeAppState()
        }
        #endif
    }

    func stop() {
        GCRumMainThread.run { [weak self] in
            guard let self else { return }
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.observers.removeAll()
            // Reported as `background` rather than a fourth reason: from the
            // consumer's side an engine teardown and leaving the foreground are
            // the same event — capture stopped, here is what was counted.
            self.emit(self.aggregator?.flush(endMs: Self.nowMs(), reason: .background))
            // AFTER the final flush, so this block's own emit still lands, and BEFORE anything
            // queued behind it runs. `recordHang` and `flushSegment` hop to main too, so a hop
            // scheduled before teardown can still execute after it and would otherwise reach
            // `onSegment` — the engine's emit — once the React bridge under it is invalidated.
            // Main-thread-only state, so no lock: every reader and writer is inside a
            // `GCRumMainThread.run`, which is what makes the ordering above meaningful at all.
            self.stopped = true
            self.aggregator = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastFrameTimestamp = link.timestamp }
        // The first tick has no predecessor to measure against.
        guard lastFrameTimestamp != 0 else { return }

        // The OBSERVED interval since the last tick — the aggregator estimates the display's actual
        // running rate from the recent stream of these, rather than trusting the link's
        // `targetTimestamp`, which reports the panel's peak on an idle ProMotion display.
        let deltaMs = (link.timestamp - lastFrameTimestamp) * 1000
        // Non-nil only when this frame pushed the segment past the safety cap.
        emit(aggregator?.record(frameDurationMs: deltaMs, nowMs: Self.nowMs()))
    }

    private func emit(_ segment: Segment?) {
        guard !stopped, let segment else { return }
        onSegment(segment)
    }

    /// Feed a hang the frame sampler could not see into the open segment as a synthetic frozen
    /// frame, so the hang is counted in iOS's `frames_frozen`. The sampler is a main-thread
    /// CADisplayLink, so a main-thread stall is a GAP it never records; the hang watchdog runs on
    /// its own thread, catches every hang, and calls this. Hops to the aggregator's thread, then
    /// resets the frame clock so the natural giant recovery-gap frame is not ALSO counted — the
    /// watchdog is the single source of truth for hang→frozen.
    func recordHang(durationMs: Double) {
        GCRumMainThread.run { [weak self] in
            guard let self else { return }
            self.lastFrameTimestamp = 0
            self.emit(self.aggregator?.recordHang(durationMs: durationMs, nowMs: Self.nowMs()))
        }
    }

    /// Closes the open segment and hands it back directly, WITHOUT going through
    /// `onSegment`: JS is changing the screen and will stamp the result with the screen
    /// being left, while the emitter stamps the ambient one. Hops to main and answers
    /// through the completion, since the aggregator is only touched from the link's thread.
    func flushSegment(reason: SegmentReason, completion: @escaping (Segment?) -> Void) {
        GCRumMainThread.run { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            completion(self.aggregator?.flush(endMs: Self.nowMs(), reason: reason))
        }
    }

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private static func displayRefreshRateHz() -> Double {
        #if canImport(UIKit)
        let maxFps = UIScreen.main.maximumFramesPerSecond
        if maxFps > 0 { return Double(maxFps) }
        #endif
        return 60
    }

    /// A backgrounded app renders nothing; without this the first frame after
    /// returning looks like a multi-minute freeze.
    private func observeAppState() {
        #if canImport(UIKit)
        observers.observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            guard let self else { return }
            // The last thing that can save this screen's counters: the app may
            // never come back, and the foreground return discards them.
            self.emit(self.aggregator?.flush(endMs: Self.nowMs(), reason: .background))
            self.displayLink?.isPaused = true
        }
        observers.observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            guard let self else { return }
            // Drop the stale timestamp so the gap across the background is not
            // counted as one enormous frame.
            self.lastFrameTimestamp = 0
            self.aggregator?.reset(nowMs: Self.nowMs())
            self.displayLink?.isPaused = false
        }
        #endif
    }
}
