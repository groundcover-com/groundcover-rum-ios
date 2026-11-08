import Foundation

/// Turns a KSCrash report into the JSON record the JS drainer reads.
///
/// Pure and KSCrash-free at the type level — it takes the already-parsed
/// dictionary — so it is unit-testable from fixture JSON with no crash, no
/// device, and no linked crash reporter. That matters: this is the piece most
/// likely to break silently, since a renamed key surfaces only as a missing
/// attribute on a crash nobody is watching.
enum GCRumCrashReportMapper {
    /// Guards against a pathological stack.
    static let maxFrames = 200
    private static let maxMessageChars = 2_000

    /// - Parameters:
    ///   - report: a parsed KSCrash report (its on-disk format is plain JSON).
    ///   - sessionSnapshotJson: the envelope the crashed run last pushed.
    /// - Returns: the record JSON, or nil when the report is unusable.
    static func buildRecord(
        report: [String: Any],
        sessionSnapshotJson: String?
    ) -> String? {
        guard let id = reportId(report) else { return nil }

        let crash = report["crash"] as? [String: Any] ?? [:]
        let error = crash["error"] as? [String: Any] ?? [:]

        var record: [String: Any] = [
            "id": id,
            "crashEpochMs": crashEpochMs(report),
            "errorType": errorType(error),
            "errorMessage": truncate(errorMessage(error)),
            "stacktrace": stacktrace(crash: crash, report: report),
            "metadata": metadata(report: report, error: error),
            "screen": screen(from: sessionSnapshotJson),
        ]
        // Kept as a STRING, not a nested object: JS parses it back out, and
        // re-encoding an envelope we never inspect would only risk mangling it.
        record["sessionSnapshotJson"] = sessionSnapshotJson ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func reportId(_ report: [String: Any]) -> String? {
        let info = report["report"] as? [String: Any] ?? [:]
        return info["id"] as? String
    }

    private static func crashEpochMs(_ report: [String: Any]) -> Int64 {
        let info = report["report"] as? [String: Any] ?? [:]
        // MICROSECONDS, not seconds. KSCrash writes this as
        //   addUIntegerElement(writer, KSCrashField_Timestamp, ksdate_microseconds())
        // in KSCrashReportC.c, and ksdate_microseconds() is
        // `tv_sec * 1_000_000 + tv_usec`. Read as seconds, a crash would land
        // a million times further into the future than it happened — still
        // delivered, and useless on arrival.
        if let microseconds = integer(info["timestamp"]) {
            return microseconds / 1000
        }
        if let text = info["timestamp"] as? String,
           let date = iso8601.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        // Unknown crash time is worse than a wrong one only if it is silently
        // wrong — 0 is unmistakable, and the drainer still ships the report.
        return 0
    }

    /// Reads a JSON number without caring how it was boxed.
    ///
    /// `JSONSerialization` hands back `NSNumber`, which bridges to anything; a
    /// hand-built dictionary holds a native `Int`, which does NOT satisfy
    /// `as? Double`. Depending on one of those shapes makes the mapper behave
    /// differently for a fixture than for a real report, and a units mistake
    /// could then pass a test.
    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let double = value as? Double { return Int64(double) }
        return nil
    }

    /// The most specific name available: an NSException's name, else the mach
    /// exception, else the signal. This is what the backend groups on.
    private static func errorType(_ error: [String: Any]) -> String {
        if let nsexception = error["nsexception"] as? [String: Any],
           let name = nsexception["name"] as? String {
            return name
        }
        if let mach = error["mach"] as? [String: Any],
           let name = mach["exception_name"] as? String {
            return name
        }
        if let signal = error["signal"] as? [String: Any],
           let name = signal["name"] as? String {
            return name
        }
        if let type = error["type"] as? String {
            return type
        }
        return "NativeCrash"
    }

    private static func errorMessage(_ error: [String: Any]) -> String {
        if let nsexception = error["nsexception"] as? [String: Any],
           let reason = nsexception["reason"] as? String {
            return reason
        }
        if let reason = error["reason"] as? String {
            return reason
        }
        if let cpp = error["cpp_exception"] as? [String: Any],
           let name = cpp["name"] as? String {
            return "C++ exception: \(name)"
        }
        if let signal = error["signal"] as? [String: Any],
           let name = signal["name"] as? String {
            return "Fatal signal \(name)"
        }
        return "Native crash"
    }

    /// Frames from where the exception was thrown, else from the CRASHED thread,
    /// in `{filename, function, lineno, colno}` — the same shape the JS error
    /// listener produces, so native and JS fatals render identically.
    ///
    /// KSCrash 2.6 keeps an NSException's or C++ exception's throw site in
    /// `crash.last_exception_backtrace`. The crashed thread then opens with the
    /// runtime's and KSCrash's own terminate handling, and where something caught
    /// and rethrew on the way (libdispatch around a block) the throw site may be
    /// unwound off it altogether.
    ///
    /// `filename` carries the binary image name and `function` where in it, in
    /// Apple's form (`backtrace_symbols`, and the native SDK's handled-error
    /// stacks): the symbol and the offset into it, else the image and the offset
    /// into it, else the bare address. A stripped release build's own frames have
    /// no symbol, and the offset into the image is what its dSYM resolves; the
    /// slid address alone never could be. Line and column stay 0: those need
    /// the dSYM, which the SDK does not have.
    private static func stacktrace(crash: [String: Any], report: [String: Any]) -> [[String: Any]] {
        if let thrown = crash["last_exception_backtrace"] as? [String: Any],
           let contents = thrown["contents"] as? [[String: Any]], !contents.isEmpty {
            return frames(contents)
        }
        guard let threads = crash["threads"] as? [[String: Any]] else { return [] }
        let crashed = threads.first { ($0["crashed"] as? Bool) == true } ?? threads.first
        guard let backtrace = crashed?["backtrace"] as? [String: Any],
              let contents = backtrace["contents"] as? [[String: Any]] else {
            return []
        }
        return frames(contents)
    }

    private static func frames(_ contents: [[String: Any]]) -> [[String: Any]] {
        contents.prefix(maxFrames).map { frame in
            [
                "filename": frame["object_name"] as? String ?? "<unknown>",
                "function": location(frame),
                "lineno": 0,
                "colno": 0,
            ]
        }
    }

    private static func location(_ frame: [String: Any]) -> String {
        let address = unsigned(frame["instruction_addr"])
        if let symbol = frame["symbol_name"] as? String, !symbol.isEmpty {
            guard let address, let start = unsigned(frame["symbol_addr"]), address >= start else {
                return symbol
            }
            return "\(symbol) + \(offset(address - start))"
        }
        if let address, let base = unsigned(frame["object_addr"]), address >= base,
           let image = frame["object_name"] as? String, !image.isEmpty {
            return "\(image) + \(offset(address - base))"
        }
        return hex(address)
    }

    private static func metadata(report: [String: Any], error: [String: Any]) -> [String: Any] {
        var metadata: [String: Any] = [
            "native": true,
            "fatal": true,
            "crash_source": "kscrash",
        ]

        if let signal = error["signal"] as? [String: Any] {
            if let name = signal["name"] as? String { metadata["signal"] = name }
            if let code = signal["code_name"] as? String { metadata["signal_code"] = code }
        }
        if let mach = error["mach"] as? [String: Any],
           let name = mach["exception_name"] as? String {
            metadata["mach_exception"] = name
        }
        if let address = error["address"] as? UInt64 {
            metadata["fault_address"] = hex(address)
        }

        let crash = report["crash"] as? [String: Any] ?? [:]
        if let threads = crash["threads"] as? [[String: Any]] {
            metadata["thread_count"] = threads.count
            if let index = threads.firstIndex(where: { ($0["crashed"] as? Bool) == true }) {
                metadata["crashed_thread"] = index
            }
        }

        // The app binary's UUID and load address, which a dSYM needs to resolve the frames
        // and which cannot be recovered after the fact. KSCrash
        // writes the load address only on the image's entry in `binary_images`,
        // never under `system`, so the app's entry is found by its UUID.
        if let system = report["system"] as? [String: Any] {
            if let uuid = system["app_uuid"] as? String {
                metadata["app_image_uuid"] = uuid
                let images = report["binary_images"] as? [[String: Any]] ?? []
                if let app = images.first(where: { ($0["uuid"] as? String) == uuid }),
                   let base = unsigned(app["image_addr"]) {
                    metadata["app_image_load_address"] = hex(base)
                }
            }
            if let state = system["application_stats"] as? [String: Any],
               let active = state["application_active"] as? Bool {
                metadata["foreground"] = active
            }
        }

        return metadata
    }

    /// The screen rides inside the snapshot; lift it so the drainer need not
    /// unpack the envelope twice.
    private static func screen(from sessionSnapshotJson: String?) -> [String: Any] {
        let empty: [String: Any] = ["name": "", "key": ""]
        guard let json = sessionSnapshotJson,
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screen = parsed["screen"] as? [String: Any] else {
            return empty
        }
        return [
            "name": screen["name"] as? String ?? "",
            "key": screen["key"] as? String ?? "",
        ]
    }

    private static func hex(_ address: UInt64?) -> String {
        guard let address else { return "<unknown>" }
        return "0x" + String(format: "%016llx", address)
    }

    private static func offset(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// An address, however it was boxed (see `integer`).
    private static func unsigned(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let value = value as? UInt64 { return value }
        if let value = value as? Int, value >= 0 { return UInt64(value) }
        return nil
    }

    private static func truncate(_ text: String) -> String {
        text.count <= maxMessageChars ? text : String(text.prefix(maxMessageChars))
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
