import Foundation

// Reports crashes that killed a previous run. A crashed session is over, and its envelope isn't the
// one this run would stamp, so the drain bypasses the events pool and sends each record as a batch
// of its own, under the snapshot the engine filed at crash time. The current session never touches
// these.
//
// At least once: the engine keeps a record until its batch is delivered, and `crash_report_id` is
// stable across redeliveries, so a duplicate can be recognised. Losing a fatal is far worse than
// reporting it twice.

/// Delivers every pending crash record, one at a time, acking each one delivered or unsalvageable;
/// `completion` runs once the pass is over. A record that wasn't delivered stays for the next
/// launch.
func drainCrashReports(
    store: CrashStore,
    config: ConfigManager,
    ids: IdGenerator,
    clock: @escaping RumClock,
    transporter: Transporter,
    completion: @escaping () -> Void
) {
    let records = parseCrashRecords(store.pendingCrashReportsJson())
    func report(from index: Int) {
        guard index < records.count else {
            completion()
            return
        }
        let record = records[index]
        reportOne(record, config: config, ids: ids, clock: clock, transporter: transporter) { ack in
            if ack { store.clearPendingCrashReports(ids: [record.id]) }
            report(from: index + 1)
        }
    }
    report(from: 0)
}

/// Whether to ack `record`: delivered, or unsalvageable.
private func reportOne(
    _ record: CrashRecord,
    config: ConfigManager,
    ids: IdGenerator,
    clock: @escaping RumClock,
    transporter: Transporter,
    ack: @escaping (Bool) -> Void
) {
    // No envelope means no session to file it under. Sending it under the current session would be
    // worse than dropping it: it would put another session's fatal into an unrelated one.
    guard var snapshot = snapshotOf(record.sessionSnapshotJson) else { return ack(true) }
    let snapshotScreen = crashScreen(of: snapshot.removeValue(forKey: "screen"))
    let screen = record.screen ?? snapshotScreen ?? ("", "")

    let enricher = EventEnricher(
        idGenerator: ids, clock: clock,
        platformAttributes: { ["screen": ["name": screen.name, "key": screen.key]] })
    var event = enricher.enrich(
        EnrichInput(
            type: "exception",
            attributes: attributes(of: record, privacy: config.privacy),
            // When it crashed, not when it was reported.
            timestamp: record.crashEpochMs.map(fractionalMsToNs)))

    // The pool runs these on addEvent; this path bypasses the pool, so it runs them itself. A
    // throwing beforeSend is unsalvageable: whether the app wanted the event is unknown, so it is
    // acked rather than retried forever. A false one is the app's choice, acked too. A throwing
    // enrichEvent costs only what it would have added: the hook gets a copy, so a throw after
    // changing it leaves the report as built.
    let options = config.config.options
    if let beforeSend = options.beforeSend {
        do {
            guard try UserHook.run({ try beforeSend(event) }) else { return ack(true) }
        } catch {
            handleError(error)
            return ack(true)
        }
    }
    if let enrichEvent = options.enrichEvent {
        let built = event
        do {
            event = try UserHook.run { try enrichEvent(copyRumEvent(built)) }
        } catch {
            handleError(error)
            event = built
        }
    }

    // The crashed session's envelope, verbatim: never the current one's.
    transporter.deliver(
        Batch(sessionAttributes: snapshot, events: [event.wireJson]), completion: ack)
}

/// The snapshot's envelope, or nil without a session id to file under.
private func snapshotOf(_ json: String?) -> [String: Any]? {
    guard let json, !json.isEmpty, let decoded = decodeJsonObject(json),
        let sessionId = decoded["session_id"] as? String, !sessionId.isEmpty
    else { return nil }
    return decoded
}

private func attributes(of record: CrashRecord, privacy: EffectivePrivacy) -> [String: Any] {
    let type = record.errorType.isEmpty ? "NativeCrash" : record.errorType
    // Masked exactly as a reported error is: a crash message routinely carries request context (a
    // URL, an Authorization header), and maskErrors is on by default.
    let opts = privacy.redactOptions(.error)
    let mask = privacy.shouldMaskErrors
    let rawMessage = record.errorMessage.isEmpty ? "Native crash" : record.errorMessage
    let message = mask ? redactText(rawMessage, opts) : rawMessage
    // The engine's own metadata only; the markers after it are the SDK's, and crash_report_id must
    // not be at the mercy of a key-name heuristic.
    var metadata =
        mask ? redactingCauseMessages(redactObject(record.metadata, opts), opts) : record.metadata
    metadata["native"] = true
    metadata["fatal"] = true
    // Stable across redeliveries, so a duplicate can be recognised.
    metadata["crash_report_id"] = record.id
    return [
        "error_type": type,
        "error_message": message,
        "error_stacktrace": record.frames.map(\.json),
        // As a reported error's, so native fatals group the same way; from the masked message, or
        // it would leak what the message just redacted.
        "error_fingerprint": "\(type):\(truncate(message, maxLength: 400))",
        "error_handled": false,
        "error_metadata": metadata,
    ]
}

/// Scans the cause chain's messages as text. Metadata redaction is by key, and `causes[].message`
/// is free text the Android engine copied in, under a key no heuristic calls sensitive; the
/// `caused by` message is usually where the real failure is described, so it is scrubbed, not
/// blanked.
private func redactingCauseMessages(_ metadata: [String: Any], _ opts: RedactOptions)
    -> [String: Any]
{
    guard let causes = metadata["causes"] as? [Any] else { return metadata }
    var out = metadata
    out["causes"] = causes.map { cause -> Any in
        guard var cause = cause as? [String: Any], let message = cause["message"] as? String else {
            return cause
        }
        cause["message"] = redactText(message, opts)
        return cause
    }
    return out
}
