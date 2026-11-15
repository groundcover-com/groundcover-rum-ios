import Foundation

/// Emission seam. The engine never imports a UI framework — it hands signals to
/// whoever started it: the React Native module or the Flutter plugin.
protocol GCRumEngineDelegate: AnyObject {
    /// - Parameters:
    ///   - kind: discriminator on the single event channel ("hang", "frame_segment"…).
    ///   - payload: JSON-encodable dictionary, decoded by the host SDK.
    func rumEngine(_ engine: GCRumEngine, didEmit kind: String, payload: [String: Any])
}

/// Facade over the feature units. Owns their lifecycle and nothing else — the
/// capture logic lives in the units so each stays independently testable.
///
/// Internal, like everything in the engine: each SDK compiles it into its own
/// module (the native SDK, the React Native pod, the Flutter plugin), so it is
/// never part of an SDK's public API and apps can't build against it.
final class GCRumEngine {
    weak var delegate: GCRumEngineDelegate?

    private var status = GCRumEngineStatus()
    private var started = false
    /// Bumped by every `start`, so deferred work can tell whether the run it was scheduled for is
    /// still the current one. Guarded by `lifecycleLock` along with `started`.
    private var startGeneration: UInt64 = 0
    private let queue = DispatchQueue(label: "com.groundcover.rum.engine", qos: .utility)
    private let snapshots: GCRumSessionSnapshotStore
    private let crashReporter: GCRumCrashReporter

    /// Guards the four feature-unit references below. They are ASSIGNED on the module queue
    /// (arm in `start`, release in `stop`, the latter also reachable from React's
    /// `invalidate()`) but READ from other threads — the hang watchdog's monitor thread calls
    /// `frameTracker?.recordHang`, the frame drain runs on `queue`, and status is read on the
    /// caller's thread. A concurrent unguarded read and release of a class reference is UB under
    /// ARC, so every access goes through the lock; a locked getter returns a RETAINED reference,
    /// so a reader that has read the tracker can never have it released out from under it. Matches
    /// GCRumSessionSnapshotStore's NSLock and the watchdog's own lock.
    private let trackersLock = NSLock()
    private var _hangWatchdog: GCRumHangWatchdog?
    private var _appStartTracker: GCRumAppStartTracker?
    private var _frameTracker: GCRumFrameTracker?
    private var _gestureTracker: GCRumGestureTracker?

    private var hangWatchdog: GCRumHangWatchdog? {
        get { trackersLock.lock(); defer { trackersLock.unlock() }; return _hangWatchdog }
        set { trackersLock.lock(); defer { trackersLock.unlock() }; _hangWatchdog = newValue }
    }
    private var appStartTracker: GCRumAppStartTracker? {
        get { trackersLock.lock(); defer { trackersLock.unlock() }; return _appStartTracker }
        set { trackersLock.lock(); defer { trackersLock.unlock() }; _appStartTracker = newValue }
    }
    private var frameTracker: GCRumFrameTracker? {
        get { trackersLock.lock(); defer { trackersLock.unlock() }; return _frameTracker }
        set { trackersLock.lock(); defer { trackersLock.unlock() }; _frameTracker = newValue }
    }
    private var gestureTracker: GCRumGestureTracker? {
        get { trackersLock.lock(); defer { trackersLock.unlock() }; return _gestureTracker }
        set { trackersLock.lock(); defer { trackersLock.unlock() }; _gestureTracker = newValue }
    }

    convenience init() {
        self.init(snapshotStore: GCRumSessionSnapshotStore())
    }

    /// Injection seam for tests: where the snapshot lives is an implementation
    /// detail of this engine, not something a host chooses.
    init(snapshotStore: GCRumSessionSnapshotStore) {
        snapshots = snapshotStore
        crashReporter = GCRumCrashReporter(store: snapshotStore)
    }

    /// Serializes the whole start/stop lifecycle, so the `started` check-then-act below is one
    /// step. The process-wide KSCrash singleton and the hang watchdog sit behind that guard, and
    /// two threads passing it both would call `install()` twice — the second told
    /// `AlreadyInstalled`, so crash capture reports as unavailable for a session that could have
    /// had it. Worse,
    /// `harvest()` DELETES what it reads, so a doubled harvest can destroy pending reports.
    ///
    /// Reachability is low (`nativeInit` is a `@ReactMethod` and RN serializes those on the
    /// native-modules queue) but not nil: `stop()` is also reachable from React's
    /// `invalidate()`, on a different thread, during the reload that re-runs `init()`.
    ///
    /// A separate lock from `trackersLock`, which guards only the unit references and is taken
    /// INSIDE this one by the `hangWatchdog` accessor — never the other way round.
    private let lifecycleLock = NSLock()

    /// Idempotent by contract: a second call (React Native fast-refresh
    /// re-initializes the SDK in place) must not re-harvest crash reports or
    /// duplicate any persisted record.
    @discardableResult
    func start(config: GCRumEngineConfig) -> GCRumEngineStatus {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !started else {
            // Re-stamped rather than returned verbatim: `gesturesAttached` is the one field whose
            // truth has moved on since the status was built. The attach happened after the first
            // `start` returned and announced itself through a signal the NEW JavaScript context
            // was not there to hear — and this early return is why it will never be announced
            // again. Left stale, the reloaded context suppresses nothing and every gesture is
            // reported twice.
            // Both fields describe THE TRACKER, so both are false when there is not one: a status
            // claiming full surface coverage while nothing is attached is a trap for the next
            // reader, even though the JavaScript side only consults coverage once
            // `gesturesAttached` is true.
            let tracker = gestureTracker
            status.gesturesAttached = tracker?.isAttached == true
            status.gesturesCoverAllSurfaces = tracker != nil && GCRumGestureTracker.coversAllSurfaces
            return status
        }
        started = true
        // Identifies THIS run for work that outlives the thread that scheduled it. `started` alone
        // cannot: a fast-refresh reload is a `stop()` followed by a `start()`, after which it is
        // true again — so a deferred emit from the previous run would pass a liveness check and be
        // reported as the new run's. See `emitHang`.
        startGeneration &+= 1
        let generation = startGeneration

        var next = GCRumEngineStatus()

        // ORDER MATTERS. The harvest pairs crashes from the PREVIOUS run with
        // the snapshot that run left behind, so it has to finish before the
        // snapshot below overwrites it — otherwise last run's fatal is
        // attributed to this run's session.
        if config.features.crashes {
            let previousRunSnapshot = snapshots.snapshotJson()
            do {
                try crashReporter.install()
                crashReporter.harvest(previousRunSnapshot: previousRunSnapshot)
                next.crashes = true
            } catch {
                // A crash reporter that will not install is not a reason to lose
                // every other signal.
                next.crashes = false
                // …but it IS a reason to tell somebody. Usually another KSCrash user owns the
                // singleton, and refusing is correct — [harvest] DELETES what it reads, so
                // harvesting a store we do not own would destroy their crashes. Staying quiet
                // would leave an app reporting no native crashes with nothing to explain it.
                // Reported rather than logged: JS owns the logger the customer sees.
                next.crashesUnavailable = String(describing: error)
            }
        }

        if config.features.hangs {
            let watchdog = GCRumHangWatchdog(
                thresholdMs: config.thresholds.hangThresholdMs
            ) { [weak self] startedAtMs, durationMs in
                // Emit off the monitor thread (containment + generation guard): see `emitHang`.
                self?.emitHang(startedAtMs: startedAtMs, durationMs: durationMs, generation: generation)
                // Feed the hang to the frame sampler too: on iOS the CADisplayLink sampler is
                // blocked by the same main-thread stall, so `frames_frozen` would otherwise miss it.
                // No-op when vitals is off (frameTracker is nil). Matches Android, where an in-frame
                // stall already lands in FrameMetrics' TOTAL_DURATION. Internal, non-throwing work,
                // so it stays on the monitor thread — the containment above is for the delegate path.
                self?.frameTracker?.recordHang(durationMs: durationMs)
            }
            watchdog.start()
            hangWatchdog = watchdog
            next.hangs = true
        }

        if config.features.appStart {
            let tracker = appStartTracker ?? GCRumAppStartTracker()
            appStartTracker = tracker
            // Launch already happened; the tracker buffered it and hands over
            // whatever it measured before anyone was listening.
            tracker.drain { [weak self] start in
                self?.emit(kind: "app_start", payload: [
                    "type": start.type,
                    "startMs": start.startMs,
                    "firstFrameMs": start.firstFrameMs,
                ])
            }
            next.appStart = true
        }

        if config.features.vitals {
            let tracker = GCRumFrameTracker(
                maxSegmentMs: config.thresholds.vitalsMaxSegmentMs
            ) { [weak self] segment in
                self?.emit(kind: "frame_segment", payload: Self.segmentPayload(segment))
            }
            tracker.start()
            frameTracker = tracker
            next.vitals = true
        }

        if config.features.gestures {
            let tracker = GCRumGestureTracker(
                onAttached: { [weak self] in
                    self?.emit(
                        kind: "gestures_attached",
                        payload: ["coversAllSurfaces": GCRumGestureTracker.coversAllSurfaces]
                    )
                }
            ) { [weak self] gesture in
                self?.emit(kind: "gesture", payload: [
                    "kind": gesture.kind,
                    "startedAtMs": gesture.startedAtMs,
                    "endedAtMs": gesture.endedAtMs,
                    "startX": gesture.startX,
                    "startY": gesture.startY,
                    "endX": gesture.endX,
                    "endY": gesture.endY,
                    "direction": gesture.direction,
                    "distanceDp": gesture.distanceDp,
                    "velocityDpS": gesture.velocityDpS,
                    "pointerCount": gesture.pointerCount,
                ])
            }
            tracker.start()
            gestureTracker = tracker
            // "armed", not "attached" — the attach is posted to the main queue and
            // has not run yet. JavaScript learns about the attach from the
            // `gestures_attached` signal above; this flag only tells it native
            // gesture capture was requested.
            next.gestures = true
            next.gesturesCoverAllSurfaces = GCRumGestureTracker.coversAllSurfaces
        }

        // Only now: the snapshot handed in at init belongs to the run STARTING.
        //
        // The clear is the unsampled path's other half, and it happens HERE rather than in a second
        // bridge call so that no window exists in which the previous run's envelope is still on
        // disk while this run is already capturing. Between `crashReporter.harvest` above and this
        // line the envelope is exactly what the harvest needed it to be; after it, a crash in this
        // run has nothing to be misattributed to.
        //
        // An envelope to install WINS over the clear, matching Android: it is a positive
        // instruction, and sending both is a caller bug rather than a state worth inventing
        // semantics for.
        //
        // Keep the `else if`: without it an unsampled launch leaves the previous run's envelope
        // on disk, and a crash in THIS run is misattributed to the session before it.
        // `GcRumEngine.kt` carries the same branch; they change together.
        if let snapshotJson = config.snapshotJson {
            snapshots.update(snapshotJson)
        } else if config.clearSnapshotAfterHarvest == true {
            snapshots.update(nil)
        }

        status = next
        emit(kind: "ping", payload: [:])
        return status
    }

    func updateSessionSnapshot(_ snapshotJson: String?) {
        queue.async { [weak self] in
            self?.snapshots.update(snapshotJson)
        }
    }

    func pendingCrashReportsJson() -> String {
        let records = snapshots.readPendingRecords()
        // Records are already JSON objects; splicing them avoids a decode/encode
        // round-trip whose only job would be to produce the same bytes.
        return "[" + records.joined(separator: ",") + "]"
    }

    func clearPendingCrashReports(ids: [String]) {
        snapshots.deletePendingRecords(ids: ids)
    }

    /// Closes the open frame segment and hands it back as JSON, or `"null"` when
    /// there is nothing to report.
    ///
    /// Takes a completion rather than returning, because the aggregator lives on
    /// the main thread (its display link runs on the main run loop) and the bridge
    /// calls this from its own queue. Resolving INSIDE the hop is what makes the
    /// answer describe the segment as it was when native handled the request.
    func flushFrameSegmentJson(completion: @escaping (String) -> Void) {
        guard let tracker = frameTracker else {
            completion("null")
            return
        }
        tracker.flushSegment(reason: .navigation) { segment in
            guard let segment,
                  let data = try? JSONSerialization.data(
                      withJSONObject: Self.segmentPayload(segment)
                  ),
                  let json = String(data: data, encoding: .utf8)
            else {
                completion("null")
                return
            }
            completion(json)
        }
    }

    /// Stops watchdogs and display links. The crash handler deliberately stays
    /// armed — a crash during teardown is still worth reporting.
    ///
    /// `stop()` is the whole teardown on iOS, unlike Android's `release()`: each tracker
    /// invalidates its own link, recognizers and observers when it is released here.
    ///
    /// `updateSessionSnapshot` posts to `queue`, which is not drained before the flush below: an
    /// update queued in the last milliseconds before `stop()` can still be written after it.
    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        snapshots.flushPendingWrite()
        hangWatchdog?.stop()
        hangWatchdog = nil
        frameTracker?.stop()
        frameTracker = nil
        gestureTracker?.stop()
        gestureTracker = nil
        appStartTracker?.stop()
        appStartTracker = nil
        started = false
        status = GCRumEngineStatus()
    }

    func emit(kind: String, payload: [String: Any]) {
        delegate?.rumEngine(self, didEmit: kind, payload: payload)
    }

    /// The one place a frame segment is turned into wire keys, so the push path
    /// (here) and the JS pull path cannot drift apart.
    static func segmentPayload(_ segment: GCRumFrameAggregator.Segment) -> [String: Any] {
        [
            "segmentStartMs": segment.startMs,
            "segmentEndMs": segment.endMs,
            "total": segment.total,
            "slow": segment.slow,
            "frozen": segment.frozen,
            "refreshRate": segment.refreshRate,
            "delayMs": segment.delayMs,
            "budgetMs": segment.budgetMs,
            "reason": segment.reason.rawValue,
        ]
    }

    /// Reports a recovered stall from the engine's own queue rather than from the watchdog's
    /// monitor thread — the containment boundary between a detector and a host.
    ///
    /// The monitor thread is the only thing that can see the NEXT stall, and everything
    /// downstream of `emit` is somebody else's code: the delegate is React's event emitter, which
    /// enqueues onto the JS thread, and JavaScript's handler runs the customer's `beforeSend`.
    /// Run inline, a host that blocks blinds the detector for as long as it blocks, and a host
    /// that dies takes the thread — after which the app hangs unobserved for the rest of the
    /// process, with nothing in the logs to say why.
    ///
    /// A queue hop, not a `try`/`catch`, because the failure this guards against is not a Swift
    /// error: an `OnHang` closure cannot throw one, and the ObjC exceptions the emitter can raise
    /// (`sendEvent` on an invalidated bridge) are not catchable from Swift at all. What is
    /// achievable is keeping them off this thread. The Android twin can be a `runCatching` in
    /// `emit` precisely because a JVM exception IS catchable there.
    ///
    /// The generation check is the cost of deferring, and it has to be a generation rather than a
    /// liveness flag. `stop()` can land between the stall recovering and this block running — an
    /// inline emit would be covered by the watchdog's own `stopped` check (see
    /// `GCRumHangRules.recoveredDurationMs`), which deferring gives up — but a fast-refresh
    /// reload is `stop()` **then** `start()`, so by the time the block runs `started` is true again
    /// and a stall belonging to the previous run would be reported as the new one's. The `and` of
    /// both conditions is what the caller actually means by "is this still my run".
    ///
    /// It also covers the teardown ordering: React's `invalidate()` calls `stop()` before tearing
    /// the bridge down, so a block that arrives during teardown fails this guard and never reaches
    /// `sendEvent`. A block already PAST the guard when `invalidate()` runs concurrently is outside
    /// what this method can order: only serializing emission and invalidation on one queue owned by
    /// the module would cover it, and that is the bridge's threading contract, not this method's.
    private func emitHang(startedAtMs: Double, durationMs: Double, generation: UInt64) {
        queue.async { [weak self] in
            guard let self, self.isCurrentRun(generation) else { return }
            self.emit(kind: "hang", payload: [
                "kind": "app_hang",
                "startedAtMs": startedAtMs,
                "durationMs": durationMs,
            ])
        }
    }

    /// Whether the engine is still running the same start that scheduled the caller's work. One
    /// lock acquisition for both halves, since a torn state between them is the thing being ruled
    /// out. Safe to take on `queue`: no holder of `lifecycleLock` ever waits on that queue, so the
    /// two can never deadlock.
    private func isCurrentRun(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return started && startGeneration == generation
    }
}
