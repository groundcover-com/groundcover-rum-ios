import GroundcoverRum
import Logging

/// A swift-log `LogHandler` that sends each message as a log event, with its metadata as the
/// event's attributes and the logger's label among them.
///
/// ```swift
/// LoggingSystem.bootstrap { label in
///     MultiplexLogHandler([
///         StreamLogHandler.standardOutput(label: label),
///         GroundcoverLogHandler(label: label),
///     ])
/// }
/// ```
///
/// Messages below ``logLevel`` (`.info` by default) are not sent, and neither is one that contains
/// `groundcoverIgnore`.
public struct GroundcoverLogHandler: LogHandler {
    public let label: String
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .info

    public init(label: String) {
        self.label = label
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    // The method every swift-log 1.x calls. From 1.11 the protocol prefers `log(event:)` and
    // warns that this one is deprecated, but 1.11 is the first release with `LogEvent`, and
    // implementing it would stop SwiftPM resolving this package beside one that pins an older 1.x.
    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let text = message.description
        // The app's own opt-out, as the other SDKs honour it.
        if text.contains("groundcoverIgnore") { return }
        var attributes: [String: Any] = ["logger": label]
        for (key, value) in self.metadata.merging(metadata ?? [:], uniquingKeysWith: { $1 }) {
            attributes[key] = Self.plain(value)
        }
        let logger = Groundcover.logger
        switch level {
        case .trace: logger.trace(text, attributes)
        case .debug: logger.debug(text, attributes)
        case .info, .notice: logger.info(text, attributes)
        case .warning: logger.warn(text, attributes)
        case .error, .critical: logger.error(text, attributes)
        }
    }

    /// swift-log's metadata value as JSON-like data: strings, lists and maps.
    static func plain(_ value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let string): return string
        case .stringConvertible(let convertible): return convertible.description
        case .array(let array): return array.map(plain)
        case .dictionary(let dictionary): return dictionary.mapValues(plain)
        }
    }
}
