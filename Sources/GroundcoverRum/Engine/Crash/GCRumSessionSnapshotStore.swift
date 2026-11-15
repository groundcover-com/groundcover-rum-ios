import Foundation

/// On-disk home for the session snapshot and pending crash records. Nothing can be
/// composed at crash time, so the snapshot must already be on disk; writes are atomic
/// (temp + replace) so a crash mid-write leaves the previous one intact, and debounced
/// so a navigating user does not write on every transition.
final class GCRumSessionSnapshotStore {
    static let maxPendingRecords = 10
    static let writeDebounce: TimeInterval = 0.5

    private let root: URL
    private let snapshotURL: URL
    private let pendingDir: URL

    /// Guards the in-memory state below. Held only for memory access — never across a disk
    /// write, because `snapshotJson()` is on the crash path and must not block on an fsync.
    private let lock = NSLock()

    /// Guards MUTATION OF THE SNAPSHOT FILE as one step: take-and-write in
    /// [flushPendingWrite], clear-and-delete in [clear]. Distinct from [lock], and always
    /// taken BEFORE it — never the other way round.
    ///
    /// Two writers must not land out of order. [flushPendingWrite] takes the parked write and
    /// clears it before touching disk, so a debounce timer, a background flush and a teardown
    /// flush can each hold a DIFFERENT envelope; with nothing serializing them the older one
    /// could finish last and become what the next crash is attributed to. And a clear that did
    /// not take this could delete the file mid-write, letting the flush put the cleared
    /// snapshot back. Matches the Kotlin twin's `writeLock`.
    private let snapshotWriteLock = NSLock()

    /// Latest snapshot, in memory. The crash path reads THIS, never the disk: at
    /// crash time the process may be moments from death and a read could be the
    /// thing that fails.
    private var snapshot: String?
    private var pendingWrite: String?
    private var lastWriteAt: TimeInterval = 0

    /// Drains a parked write once the debounce window closes.
    ///
    /// The debounce has to be TRAILING, not just rate-limiting: a jetsam kill, an
    /// OOM or a native crash gives us neither `stop()` nor a background
    /// transition, and whatever is on disk at that instant is what the crash gets
    /// attributed to. Without this the newest envelope can sit in memory
    /// indefinitely — JS re-pushes on init and on every screen change, so an
    /// update inside the previous one's window is the ordinary case.
    private let flushQueue = DispatchQueue(label: "com.groundcover.rum.snapshot-flush")
    private var scheduledFlush: DispatchWorkItem?

    /// How a composed snapshot reaches its final path.
    ///
    /// Injectable ONLY so a test can hold a write open mid-flight and prove that a
    /// concurrent clear cannot be overtaken by it — the race [snapshotWriteLock] exists to
    /// prevent, and one that no amount of sleeping reproduces reliably from the outside.
    /// Mirrors the Kotlin twin's `renameFile` seam, which exists for the same reason.
    /// Production uses the real atomic replace.
    private let writeSnapshot: (String, URL) -> Void

    init(
        directory: URL? = nil,
        writeSnapshot: ((String, URL) -> Void)? = nil
    ) {
        self.writeSnapshot = writeSnapshot ?? Self.writeAtomically
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("groundcover-rum", isDirectory: true)

        root = base
        snapshotURL = base.appendingPathComponent("snapshot.json")
        pendingDir = base.appendingPathComponent("pending", isDirectory: true)

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        // A JSON OBJECT, not merely readable. The record path already demands that of what it
        // feeds the drain (`isJsonObject` in `readPendingRecords`), and the snapshot feeds the
        // same consumer: without the check, an empty or truncated file would become a non-nil
        // envelope that the JS drain then has to reject. Kotlin's `readSnapshotFile` applies the
        // identical predicate.
        snapshot = (try? String(contentsOf: snapshotURL, encoding: .utf8))
            .flatMap { Self.isJsonObject($0) ? $0 : nil }
    }

    /// Keeps the envelope out of iCloud and iTunes backups. What is on disk is the exact
    /// `sessionAttributes` a live batch carries — whatever `identifyUser` was given, often
    /// an email — and Application Support is backed up by default.
    ///
    /// Excluded rather than moved to Caches, because the OS may evict Caches under disk
    /// pressure and destroy crash reports that have not reached the network. Excluding keeps
    /// the durability and needs no migration.
    ///
    /// Applied on EVERY init, not only at creation: `createDirectory` is a no-op once the
    /// directory exists, so applying this only at creation would miss any directory that
    /// already does. That repetition is also what makes swallowing safe.
    /// Best-effort, like every disk operation here — the alternative is failing init.
    private static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The snapshot currently in memory.
    ///
    /// Its meaning depends on WHEN it is read, and both readers are deliberate:
    /// before the engine's first `update` it is what the PREVIOUS run left on
    /// disk (the session a harvested crash belongs to); during the run it is the
    /// live session. Always served from memory — the crash path reads it with
    /// the process moments from death, where a disk read is what fails.
    func snapshotJson() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func update(_ json: String?) {
        guard let json else {
            clear()
            return
        }

        lock.lock()
        snapshot = json
        pendingWrite = json
        let now = Date().timeIntervalSince1970
        let due = now - lastWriteAt >= Self.writeDebounce
        if due {
            lock.unlock()
            flushPendingWrite()
            return
        }

        // Not due: park it, and make sure something drains it. One timer is
        // enough — it picks up whatever `pendingWrite` holds when it fires, so
        // later updates inside the same window coalesce into it rather than
        // stacking up timers.
        if scheduledFlush == nil {
            let delay = max(0, Self.writeDebounce - (now - lastWriteAt))
            let item = DispatchWorkItem { [weak self] in self?.flushPendingWrite() }
            scheduledFlush = item
            lock.unlock()
            flushQueue.asyncAfter(deadline: .now() + delay, execute: item)
            return
        }
        lock.unlock()
    }

    /// Drops the envelope from memory and from disk.
    ///
    /// Cancelling the timer is not enough on its own: `cancel()` cannot stop a flush that has
    /// ALREADY started, so an unsynchronized delete could land inside [flushPendingWrite]'s
    /// take-and-write. The flush would then finish with the envelope it had already captured and
    /// write the cleared snapshot back, where the next launch reads it — a crash reported under
    /// the session and user JavaScript had just said were gone.
    ///
    /// Hence [snapshotWriteLock] around the whole clear, taken BEFORE [lock] — the one order
    /// both this and [flushPendingWrite] use. `snapshot` is nilled under [lock] only, so a
    /// crash-path read never waits on the delete.
    private func clear() {
        snapshotWriteLock.lock()
        defer { snapshotWriteLock.unlock() }

        lock.lock()
        snapshot = nil
        pendingWrite = nil
        scheduledFlush?.cancel()
        scheduledFlush = nil
        lock.unlock()

        try? FileManager.default.removeItem(at: snapshotURL)
    }

    /// Forces the debounced write out. Called before the process is likely to be
    /// suspended or killed (background transition), and by the trailing-edge
    /// timer that `update` arms.
    func flushPendingWrite() {
        // Take-and-write as ONE step — see [snapshotWriteLock]. Held across the disk write,
        // which is why it cannot be [lock]: that one is read on the crash path.
        snapshotWriteLock.lock()
        defer { snapshotWriteLock.unlock() }

        lock.lock()
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard let json = pendingWrite else {
            lock.unlock()
            return
        }
        pendingWrite = nil
        lastWriteAt = Date().timeIntervalSince1970
        lock.unlock()

        writeSnapshot(json, snapshotURL)
    }

    func writePendingRecord(id: String, json: String) {
        // Same guard as the ack path: the id is interpolated into a path. Refusing here also
        // means an id that could never be acked can never be written, so the two halves cannot
        // disagree and strand a record nothing is able to delete.
        guard Self.isSafeRecordId(id) else { return }
        enforceRecordCap()
        Self.writeAtomically(json, to: pendingDir.appendingPathComponent("\(id).json"))
    }

    func readPendingRecords() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate(of: $0) < modificationDate(of: $1) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            // Only records that are actually a JSON OBJECT survive, and this is a correctness
            // filter rather than tidiness: the engine splices these strings into
            // `"[" + joined(",") + "]"`, so a single unparseable file makes JavaScript's
            // `JSON.parse` throw and the drain loses EVERY pending crash rather than the one bad
            // file — leaving all of them un-acked and redelivered forever.
            //
            // Blankness is not a sufficient test. The likelier shape is a TRUNCATED write — a
            // record interrupted by the very crash being recorded leaves `{"id":"ab`, which is
            // non-blank and poisons the splice just the same. A valid non-object (`"a string"`)
            // parses but then has no fields for the drain to read.
            //
            // Mirrors GcRumSnapshotStore.readPendingRecords, deliberately: both platforms splice,
            // so both need the same predicate or they disagree about what a record is.
            .filter { Self.isJsonObject($0) }
    }

    func deletePendingRecords(ids: [String]) {
        for id in ids {
            // The id is interpolated into a path, so `../` would escape the pending
            // directory and delete whatever it named. Low reachability — the ids are
            // generated natively and read back from inside the app sandbox — but the ack
            // path costs one comparison to make safe, and an ack has no business naming
            // anything but a basename.
            guard Self.isSafeRecordId(id) else { continue }
            try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent("\(id).json"))
        }
    }

    /// Whether a persisted record is a JSON object the drain can actually read.
    ///
    /// `JSONSerialization` rejects anything that is not valid JSON — blank, truncated — and the
    /// dictionary cast rejects a valid non-object, which is exactly the set that must not reach
    /// the splice.
    static func isJsonObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              parsed is [String: Any]
        else { return false }
        return true
    }

    /// Whether a record id names a file directly inside the pending directory and nothing
    /// else. Checked by comparing against the last path component rather than by hunting for
    /// `..`, so an encoding this does not anticipate fails CLOSED.
    static func isSafeRecordId(_ id: String) -> Bool {
        !id.isEmpty && id == (id as NSString).lastPathComponent && !id.hasPrefix(".")
    }

    /// Drop-oldest once the cap is reached. An app that crashes repeatedly
    /// without ever reaching a working network must not grow unbounded.
    private func enforceRecordCap() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []).filter { $0.pathExtension == "json" }

        guard files.count >= Self.maxPendingRecords else { return }
        files
            .sorted { modificationDate(of: $0) < modificationDate(of: $1) }
            .prefix(files.count - Self.maxPendingRecords + 1)
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// `static` so it can be the default for [writeSnapshot]: it touches no instance state,
    /// only its arguments.
    private static func writeAtomically(_ contents: String, to target: URL) {
        // `.atomic` writes a temp file and replaces, so a crash mid-write leaves the
        // previous contents. The protection class rides on the WRITE rather than the
        // directory, because the replacement inode inherits nothing from the old one.
        //
        // …UntilFirstUserAuthentication, not `.complete`: under `.complete` a write fails
        // while the device is locked, which is exactly when the background flush runs.
        try? Data(contents.utf8).write(
            to: target,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
