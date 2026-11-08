import Foundation

// The screen every event is stamped with, and the navigation events between screens.

/// A screen change: from a screen source (a view controller, a SwiftUI screen), or the manual
/// navigation API.
enum NavigationCapture {
    /// A screen became current. The pipeline stamps it on every later event and reports the
    /// navigation, with the screen it left and how long that one was shown. An empty name is
    /// ignored.
    case screen(name: String, key: String)

    /// `Groundcover.startNavigation`. A blank screen is dropped at its end.
    case start(screen: String, key: String, metadata: [String: Any]?)

    /// `Groundcover.endNavigation`: reports the navigation started last, with both calls'
    /// metadata merged.
    case end(metadata: [String: Any]?)
}

/// The screen stamped on events, the automatic sources' last screen (which a manual navigation
/// does not move), and the manual navigation in progress.
final class NavigationTracker {
    /// The current screen, set before a navigation is built, so the navigation and everything after
    /// it carry it. Empty before the first.
    private(set) var screenName = ""
    private(set) var screenKey = ""

    private var lastName = ""
    private var lastKey = ""

    /// When the last automatic screen became current; 0 before the first.
    private var lastChangeMs: Int64 = 0

    private var manual: (name: String, key: String, metadata: [String: Any]?, startMs: Int64)?

    /// The navigation event `capture` completes at `nowMs`, if any.
    func handle(_ capture: NavigationCapture, nowMs: Int64, privacy: EffectivePrivacy)
        -> EnrichInput?
    {
        switch capture {
        case .screen(let name, let key):
            return onScreen(name: name, key: key, nowMs: nowMs, privacy: privacy)
        case .start(let screen, let key, let metadata):
            let name = isBlank(screen) ? "" : screen
            let manualKey = isBlank(key) ? "" : key
            manual = (name, manualKey, metadata, nowMs)
            if !name.isEmpty {
                screenName = name
                screenKey = manualKey
            }
            return nil
        case .end(let metadata):
            let active = manual
            manual = nil
            // A record with no screen name is never shipped.
            guard let active, !active.name.isEmpty else { return nil }
            screenName = active.name
            screenKey = active.key
            var merged = active.metadata ?? [:]
            for (key, value) in metadata ?? [:] { merged[key] = value }
            return navigation(
                privacy, durationMs: nowMs - active.startMs, metadata: merged,
                startMs: active.startMs, endMs: nowMs)
        }
    }

    private func onScreen(name: String, key: String, nowMs: Int64, privacy: EffectivePrivacy)
        -> EnrichInput?
    {
        if name.isEmpty || (name == lastName && key == lastKey) { return nil }
        let from = lastName
        let fromKey = lastKey
        let durationMs = lastChangeMs == 0 ? 0 : nowMs - lastChangeMs
        lastName = name
        lastKey = key
        screenName = name
        screenKey = key
        lastChangeMs = nowMs
        return navigation(
            privacy, from: from, fromKey: fromKey, durationMs: durationMs,
            startMs: nowMs - durationMs, endMs: nowMs)
    }

    private func navigation(
        _ privacy: EffectivePrivacy, from: String = "", fromKey: String = "", durationMs: Int64,
        metadata: [String: Any]? = nil, startMs: Int64, endMs: Int64
    ) -> EnrichInput {
        var attributes: [String: Any] = [
            "duration_ms": durationMs,
            "start_timestamp": msToNs(startMs),
            "end_timestamp": msToNs(endMs),
        ]
        if !from.isEmpty { attributes["from_screen"] = from }
        if !fromKey.isEmpty { attributes["from_key"] = fromKey }
        if let redacted = redactMetadata(metadata, privacy) { attributes["metadata"] = redacted }
        return EnrichInput(type: "navigation", attributes: attributes)
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
