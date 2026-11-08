// Interaction shaping, as the React Native SDK does it: the label, hint and value text are masked
// under mask-all or maskInteractionLabels, or when the element is private; the role, state flags
// and component path are structural, and always kept.

private let maskedLabel = "***"

/// A tap, a gesture or a finished edit, as an `interaction` event.
func shapeInteractionEvent(_ capture: InteractionCapture, privacy: EffectivePrivacy) -> EnrichInput
{
    let target = capture.target
    let mask = privacy.maskInteractionLabels || target.masked
    var targetAttributes: [String: Any] = [
        "component": target.component,
        "label": mask ? maskedLabel : target.label,
        "role": target.role,
        "hint": mask && !target.hint.isEmpty ? maskedLabel : target.hint,
    ]
    if let state = target.state, !state.isEmpty { targetAttributes["state"] = state }
    if let valueText = target.valueText {
        targetAttributes["value"] = ["text": mask ? maskedLabel : valueText]
    }
    var attributes: [String: Any] = [
        "interaction_type": capture.kind.rawValue,
        "interaction_target": targetAttributes,
        "interaction_component_path": target.componentPath,
    ]
    if let x = capture.x, let y = capture.y {
        attributes["interaction_coordinates"] = ["x": x, "y": y]
    }
    if let gesture = capture.gesture {
        var measure: [String: Any] = [
            "distance_dp": gesture.distanceDp,
            "velocity_dp_s": gesture.velocityDpS,
            "duration_ms": gesture.durationMs,
            "pointer_count": gesture.pointerCount,
            "capture_source": "native",
        ]
        if let direction = gesture.direction { measure["direction"] = direction.rawValue }
        if gesture.partial { measure["partial"] = true }
        attributes["interaction_gesture"] = measure
    }
    return EnrichInput(type: "interaction", attributes: attributes, timestamp: capture.timestampNs)
}
