/// One captured event, as ``BeforeSend`` and ``EnrichEvent`` see it.
///
/// The ``attributes`` are dot-flattened before the hooks run, so a tap's
/// `interaction_target: {label}` arrives as `"interaction_target.label"`. The one nested
/// attribute is `screen`, added after flattening. Timestamps are nanoseconds since the epoch.
///
/// An `enrichEvent` hook may change anything here except ``type`` and ``id``, and returns the
/// event: this one or a new one.
public final class RumEvent {
    /// `interaction`, `network`, `log`, `navigation`, `custom`, `exception` or `performance`.
    public let type: String

    public let id: String
    public var spanId: String
    public var parentSpanId: String?
    public var traceId: String?
    public var timestamp: Int64?

    /// A network event is a span: it has these instead of ``timestamp``.
    public var startTimestamp: Int64?
    public var endTimestamp: Int64?

    /// `"METHOD path"`, on network events only.
    public var spanName: String?

    public var attributes: [String: Any]

    public init(
        type: String,
        id: String,
        spanId: String,
        parentSpanId: String? = nil,
        traceId: String? = nil,
        timestamp: Int64? = nil,
        startTimestamp: Int64? = nil,
        endTimestamp: Int64? = nil,
        spanName: String? = nil,
        attributes: [String: Any] = [:]
    ) {
        self.type = type
        self.id = id
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.traceId = traceId
        self.timestamp = timestamp
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.spanName = spanName
        self.attributes = attributes
    }
}
