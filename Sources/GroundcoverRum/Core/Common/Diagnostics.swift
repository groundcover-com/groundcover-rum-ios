import Foundation

/// The SDK's own log, under a `[groundcover]` prefix: ``log(_:detail:)`` only when `debug` is on,
/// ``warn(_:)`` whatever the setting, for misconfiguration the developer has to see.
final class RumDiagnostics: @unchecked Sendable {
    /// The one the SDK writes through: diagnostics have no owner to inject them through. NSLog
    /// rather than os.Logger, whose import would join the module's public interface.
    static let shared = RumDiagnostics(sink: { line in NSLog("%@", line) })

    private static let emittingKey = "com.groundcover.rum.diagnosticsEmitting"
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let sink: (String) -> Void
    private let lock = NSLock()
    private var debug = false

    init(sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    var isDebug: Bool {
        lock.lock()
        defer { lock.unlock() }
        return debug
    }

    func configure(debug: Bool? = nil) {
        guard let debug else { return }
        lock.lock()
        self.debug = debug
        lock.unlock()
    }

    func log(_ message: String, detail: Any? = nil) {
        guard isDebug else { return }
        let suffix = detail.map { " \($0)" } ?? ""
        emit("[\(Self.timestamps.string(from: Date()))] [groundcover] \(message)\(suffix)")
    }

    func warn(_ message: String) {
        emit(message)
    }

    // A line can only arrive from inside the sink through an app that routes what the SDK writes
    // back into the SDK's logger; written, each line would write another, without end.
    private func emit(_ line: String) {
        let thread = Thread.current.threadDictionary
        guard thread[Self.emittingKey] == nil else { return }
        thread[Self.emittingKey] = true
        defer { thread[Self.emittingKey] = nil }
        sink(line)
    }
}

/// Swallows `error` after logging it in debug. Every SDK boundary that must not throw into the host
/// ends here.
func handleError(_ error: Error) {
    RumDiagnostics.shared.log("[error-handler.handleError] called", detail: error)
}

/// A warning the developer sees even with debug off.
func safeWarn(_ message: String) {
    RumDiagnostics.shared.warn(message)
}
