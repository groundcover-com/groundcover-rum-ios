/// The privacy settings every capture path reads, resolved once from the `privacy` options.
struct EffectivePrivacy {
    var level: PrivacyLevel

    /// The per-surface toggles, already false under ``PrivacyLevel/allow``.
    var maskNetworkBodies: Bool
    var maskNetworkQueryParams: Bool
    var maskLogs: Bool
    var maskErrors: Bool

    var sensitiveKeys: [String]
    var redact: Redactor?

    /// Mask tap labels. On under ``PrivacyLevel/maskAll`` whatever the toggle says.
    var maskInteractionLabels: Bool

    // The `level != allow && maskX` gates, in one place so no capture path re-derives them.
    var shouldMaskNetworkBodies: Bool { level != .allow && maskNetworkBodies }
    var shouldMaskNetworkQueryParams: Bool { level != .allow && maskNetworkQueryParams }
    var shouldMaskLogs: Bool { level != .allow && maskLogs }
    var shouldMaskErrors: Bool { level != .allow && maskErrors }
}

/// Trimmed, non-empty strings only.
func normalizeStringList(_ values: [String]?) -> [String] {
    (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

/// Effective privacy from the provided options. An omitted level means
/// ``PrivacyLevel/maskSensitive``, and every per-surface toggle defaults on unless the level is
/// ``PrivacyLevel/allow``.
func resolvePrivacy(_ privacy: PrivacyOptions?) -> EffectivePrivacy {
    let level = privacy?.level ?? .maskSensitive
    let isAllow = level == .allow
    func orDefaultOn(_ value: Bool?) -> Bool { isAllow ? false : value ?? true }

    return EffectivePrivacy(
        level: level,
        maskNetworkBodies: orDefaultOn(privacy?.maskNetworkBodies),
        maskNetworkQueryParams: orDefaultOn(privacy?.maskNetworkQueryParams),
        maskLogs: orDefaultOn(privacy?.maskLogs),
        maskErrors: orDefaultOn(privacy?.maskErrors),
        sensitiveKeys: normalizeStringList(privacy?.sensitiveKeys),
        redact: privacy?.redact,
        // As RN: mask-all always masks labels; the toggle only adds masking.
        maskInteractionLabels: level == .maskAll || privacy?.maskInteractionLabels == true)
}
