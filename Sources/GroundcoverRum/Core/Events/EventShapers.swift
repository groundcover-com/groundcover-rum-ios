// The events the app sends itself: custom events and logs.

/// `Groundcover.sendCustomEvent`, sent as given: custom events are not auto-redacted.
func shapeCustomEvent(_ capture: CustomEventCapture) -> EnrichInput {
    EnrichInput(
        type: "custom",
        attributes: [
            "custom_event_name": capture.name,
            "custom_event_attributes": capture.attributes,
        ],
        timestamp: capture.timestampNs)
}

/// A log line. The keys the event stamps itself (`message`, `level`, and the enricher's
/// `reservedKeys`) are stripped from the user's attributes, so they can't be shadowed; then the
/// log privacy rules apply to the message and the attributes alike.
func shapeLogEvent(_ capture: LogCapture, privacy: EffectivePrivacy, reservedKeys: [String] = [])
    -> EnrichInput
{
    var userAttributes = capture.attributes ?? [:]
    for key in ["message", "level"] + reservedKeys {
        userAttributes[key] = nil
    }
    let safe = redactLogFields(privacy, message: capture.message, attributes: userAttributes)
    var attributes = safe.attributes ?? [:]
    attributes["message"] = truncate(safe.message)
    attributes["level"] = capture.level.rawValue
    return EnrichInput(type: "log", attributes: attributes, timestamp: capture.timestampNs)
}
