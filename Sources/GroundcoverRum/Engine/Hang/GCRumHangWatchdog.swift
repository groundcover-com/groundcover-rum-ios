import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Detects main-thread stalls — the iOS equivalent of an Android ANR, except
/// iOS rarely kills the app for one, so the user just sits there watching a
/// frozen screen.
///
/// The mechanism is a heartbeat, not a timer on the main thread: the main thread
/// bumps a counter from a repeating run-loop block, and a separate sleeping
/// thread checks how stale that counter is. A timer scheduled ON the main thread
/// could not fire during the very stall it is meant to detect.
final class GCRumHangWatchdog {
    /// Emitted on RECOVERY. A stall that kills the process instead never arrives
    /// here — that death shows up post-mortem, from the system.
    typealias OnHang = (_ startedAtMs: Double, _ durationMs: Double) -> Void

    private let thresholdMs: Double
    private let onHang: OnHang
    private let heartbeatInterval = GCRumHangRules.heartbeatInterval
    private let monitorInterval: TimeInterval

    private var timer: Timer?
    private var monitor: Thread?
    /// Guards the state below, and parks the monitor while the app is away.
    private let condition = NSCondition()

    private var lastBeat = Date().timeIntervalSince1970
    private var paused = false
    private var stopped = false
    private let observers = GCRumNotificationObservers()

    init(thresholdMs: Double, onHang: @escaping OnHang) {
        self.thresholdMs = thresholdMs
        self.onHang = onHang
        monitorInterval = GCRumHangRules.monitorInterval(thresholdMs: thresholdMs)
    }

    func start() {
        beat()
        scheduleHeartbeat()
        observeAppState()

        let monitor = Thread { [weak self] in self?.monitorLoop() }
        monitor.name = "com.groundcover.rum.hang-watchdog"
        monitor.qualityOfService = .utility
        monitor.start()
        self.monitor = monitor
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()

        // Invalidate on the thread that installed it, as Timer requires.
        GCRumMainThread.run { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
        observers.removeAll()
    }

    /// The heartbeat MUST be installed from the main thread. A timer added to
    /// `RunLoop.main` from another thread may never fire, and a heartbeat that
    /// never beats does not fail loudly: the monitor sees a counter that has
    /// been stale since launch, concludes the app is hung, and then blocks
    /// forever waiting for a recovery that can never arrive — so no hang is
    /// ever reported. The engine is armed off-main, hence the hop.
    private func scheduleHeartbeat() {
        GCRumMainThread.run { [weak self] in
            guard let self, self.timer == nil, !self.isStopped else { return }
            let timer = Timer(timeInterval: self.heartbeatInterval, repeats: true) { [weak self] _ in
                self?.beat()
            }
            // Up to half an interval late is nothing against a threshold of seconds, and lets the
            // system fire it alongside other wakeups rather than on its own, ten times a second.
            timer.tolerance = self.heartbeatInterval / 2
            // .common, so the heartbeat keeps running while the user scrolls — a
            // default-mode timer stops during tracking and every scroll would look
            // like a hang.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // The hop cost time; do not let it count against the first window.
            self.beat()
        }
    }

    private func beat() {
        condition.lock()
        lastBeat = Date().timeIntervalSince1970
        condition.unlock()
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func monitorLoop() {
        while true {
            // Parked while the app is away: nothing can stall then, and polling would wake the CPU
            // every interval for as long as an app that runs in the background stays alive. While
            // waiting for a stall the monitor looks less often than the main thread beats: how
            // often it looks here only decides how soon a stall is noticed.
            condition.lock()
            while paused && !stopped {
                condition.wait()
            }
            condition.unlock()

            Thread.sleep(forTimeInterval: monitorInterval)

            condition.lock()
            if stopped {
                condition.unlock()
                return
            }
            let isPaused = paused
            let since = Date().timeIntervalSince1970 - lastBeat
            condition.unlock()

            guard !isPaused, since * 1000 >= thresholdMs else { continue }

            // Stalled. Wait it out so the report can carry a real duration —
            // "the main thread was blocked" is far less actionable than "the
            // main thread was blocked for 4.2 seconds". At the heartbeat's interval, not the
            // monitor's: once the main thread is back it keeps beating, and the duration ends at
            // the latest beat, so every moment between recovery and this look would count as hung.
            let startedAt = Date().timeIntervalSince1970 - since
            while true {
                Thread.sleep(forTimeInterval: heartbeatInterval)
                condition.lock()
                let recovered = lastBeat > startedAt
                let done = stopped || paused
                condition.unlock()
                if recovered || done { break }
            }

            condition.lock()
            let wasStopped = stopped
            let recoveredAt = lastBeat
            condition.unlock()

            // The wait above breaks for three different reasons and only one of
            // them is a hang the user lived through — see GCRumHangRules, where
            // that judgement is testable without a thread or a run loop.
            if let durationMs = GCRumHangRules.recoveredDurationMs(
                startedAt: startedAt,
                lastBeat: recoveredAt,
                stopped: wasStopped
            ) {
                onHang(startedAt * 1000, durationMs)
            }
        }
    }

    /// A backgrounded app is suspended, not hung. Without this every return from
    /// the background would report a "hang" as long as the app was away.
    ///
    /// Both notifications arrive on the main thread, which owns the heartbeat timer.
    private func observeAppState() {
        #if canImport(UIKit)
        observers.observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            guard let self else { return }
            self.setPaused(true)
            // Nothing to beat for until the app returns. Left running, the timer would wake the
            // CPU ten times a second, for hours in an app that runs in the background (audio,
            // navigation).
            self.timer?.invalidate()
            self.timer = nil
        }
        observers.observe(UIApplication.willEnterForegroundNotification) { [weak self] in
            guard let self else { return }
            self.beat()
            self.scheduleHeartbeat()
            self.setPaused(false)
        }
        #endif
    }

    private func setPaused(_ value: Bool) {
        condition.lock()
        paused = value
        condition.broadcast()
        condition.unlock()
    }
}
