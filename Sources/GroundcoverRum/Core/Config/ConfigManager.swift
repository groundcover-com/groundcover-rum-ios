/// Holds the configuration, memoises the resolved privacy, and applies updates. Session identity
/// lives in the session state.
final class ConfigManager {
    let config: SdkConfig
    private var resolvedPrivacy: EffectivePrivacy?

    init(_ input: GroundcoverConfig) {
        config = SdkConfig(input)
    }

    /// Read on every captured event, so memoised; an update drops the memo.
    var privacy: EffectivePrivacy {
        if let resolvedPrivacy { return resolvedPrivacy }
        let resolved = resolvePrivacy(config.options.privacy)
        resolvedPrivacy = resolved
        return resolved
    }

    func update(_ update: GroundcoverConfigUpdate) {
        config.update(update)
        resolvedPrivacy = nil
    }
}
