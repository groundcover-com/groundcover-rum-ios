import Foundation

extension RumEvent {
    /// The event as the wire carries it. A network event has `start_timestamp` (and
    /// `end_timestamp` when known) instead of `timestamp`.
    var wireJson: [String: Any] {
        var json: [String: Any] = [
            "type": type,
            "id": id,
            "spanId": spanId,
            "parentSpanId": parentSpanId as Any? ?? NSNull(),
            "traceId": traceId as Any? ?? NSNull(),
            "attributes": attributes,
        ]
        if let spanName { json["span_name"] = spanName }
        if let timestamp { json["timestamp"] = timestamp }
        if let startTimestamp { json["start_timestamp"] = startTimestamp }
        if let endTimestamp { json["end_timestamp"] = endTimestamp }
        return json
    }
}

/// `event` with its attributes copied all the way down, through JSON as the wire carries them, so
/// a hook's changes to the copy never reach it. Next to the wire form, so a field added to the
/// event is copied too.
func copyRumEvent(_ event: RumEvent) -> RumEvent {
    RumEvent(
        type: event.type,
        id: event.id,
        spanId: event.spanId,
        parentSpanId: event.parentSpanId,
        traceId: event.traceId,
        timestamp: event.timestamp,
        startTimestamp: event.startTimestamp,
        endTimestamp: event.endTimestamp,
        spanName: event.spanName,
        attributes: decodeJsonObject(encodeJson(event.attributes)) ?? [:])
}
