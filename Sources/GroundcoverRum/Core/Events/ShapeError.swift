// Capture and stack parsing are the platform's; every source hands its error here, so every SDK's
// exceptions group identically.

/// The `exception` event for `error`.
func shapeErrorEvent(_ error: ErrorCapture, privacy: EffectivePrivacy) -> EnrichInput {
    let opts = privacy.redactOptions(.error)
    let shouldMask = privacy.shouldMaskErrors
    let message = error.message.isEmpty ? "Unknown error" : error.message
    let safeMessage = shouldMask ? redactText(message, opts) : message
    let safeMetadata = shouldMask ? error.metadata.map { redactObject($0, opts) } : error.metadata
    let type = error.type.isEmpty ? "Error" : error.type

    var attributes: [String: Any] = [
        "error_type": type,
        "error_message": safeMessage,
        "error_stacktrace": error.frames.map(\.json),
        "error_fingerprint": "\(type):\(truncate(safeMessage, maxLength: 400))",
        "error_handled": error.handled,
    ]
    // Omitted rather than null when there is none, as JSON.stringify drops an undefined field.
    if let safeMetadata { attributes["error_metadata"] = safeMetadata }
    return EnrichInput(type: "exception", attributes: attributes, timestamp: error.timestampNs)
}
