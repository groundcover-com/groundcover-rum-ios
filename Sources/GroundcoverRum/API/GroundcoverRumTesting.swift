import Foundation

/// Hooks for an app's tests and for end-to-end harnesses. Not for production code.
///
/// The session hooks change the persisted session state the SDK reads when it starts, so their
/// effect shows on the next launch, exactly as it would in the field, and no harness depends on
/// the SDK's storage.
///
/// The crash and hang hooks work in development builds only: on a simulator, or in a build signed
/// with a development profile. Anywhere else, Ad Hoc and Enterprise builds included, they do
/// nothing.
public enum GroundcoverRumTesting {
    /// Sets the stored last-activity time to `interval` seconds ago. Past 30 minutes, the next
    /// launch starts a new session.
    public static func backdateLastActivity(by interval: TimeInterval) {
        let ms = Int64((Date().timeIntervalSince1970 - interval) * 1000)
        SessionStorage.defaults.set(String(ms), forKey: SessionStorage.lastActivityKey)
    }

    /// Sets the stored session start to `interval` seconds ago. Past `sessionMaxDuration`, the
    /// next launch starts a new session.
    public static func backdateSessionStart(by interval: TimeInterval) {
        let ns = Int64((Date().timeIntervalSince1970 - interval) * 1000) * 1_000_000
        SessionStorage.defaults.set(String(ns), forKey: SessionStorage.startTimeKey)
    }

    /// Forgets the persisted session: its id, start, last activity and sampling verdict. The next
    /// launch starts a session no user has touched yet.
    public static func forgetSession() {
        for key in SessionStorage.sessionKeys {
            SessionStorage.defaults.removeObject(forKey: key)
        }
    }

    /// Crashes the app with a real signal, a write through a bad pointer on the main thread, so
    /// the crash reporter records it as it would a genuine crash. Returns first: the crash is
    /// queued to the main thread.
    public static func triggerTestCrash() {
        guard isDevelopmentBuild else { return }
        DispatchQueue.main.async {
            let pointer = UnsafeMutablePointer<Int>(bitPattern: 0x10)
            pointer?.pointee = 1
        }
    }

    /// Blocks the main thread for `duration` seconds, at most 30, so the hang watchdog fires.
    /// Returns first: the block is queued to the main thread.
    public static func blockMainThread(for duration: TimeInterval) {
        guard isDevelopmentBuild else { return }
        let bounded = min(max(duration, 0), 30)
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: bounded)
        }
    }

    /// Stops the SDK, so a test that started it can end cleanly: its hooks stay installed but go
    /// quiet, and the crash reporter stays armed. A later ``Groundcover/start(_:)`` starts afresh.
    public static func reset() {
        Instrumentation.shared.disarm()
        RumRuntime.shared.reset()
        InteractiveMarks.shared.reset()
    }

    /// Whether the host app is a development build, asked at runtime: a package's own `#if DEBUG`
    /// says nothing about the app it ends up in. A simulator always is; on a device, the app's
    /// embedded profile has to be a development one (see ``isDevelopmentProfile(_:)``). Gated
    /// rather than merely undocumented: a reachable "crash the app" call in a shipped build is a
    /// liability no amount of naming prevents.
    private static let isDevelopmentBuild: Bool = {
        #if targetEnvironment(simulator)
            return true
        #else
            let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            return profile.flatMap { try? Data(contentsOf: $0) }.map(isDevelopmentProfile) ?? false
        #endif
    }()

    /// Whether a provisioning profile is a development one: its `get-task-allow` entitlement, which
    /// lets a debugger attach, is true only there. Ad Hoc and Enterprise profiles carry it false,
    /// and an App Store build has no profile at all. The profile is a signed envelope around an XML
    /// property list, which is read as it stands.
    static func isDevelopmentProfile(_ profile: Data) -> Bool {
        guard let start = profile.range(of: Data("<?xml".utf8)),
            let end = profile.range(
                of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
            let plist = try? PropertyListSerialization.propertyList(
                from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else { return false }
        return entitlements["get-task-allow"] as? Bool ?? false
    }
}

/// Where the session state persists: the Flutter SDK's suite, keys and string values, so the two
/// SDKs keep one format.
enum SessionStorage {
    static let defaults = UserDefaults(suiteName: "com.groundcover.rum") ?? .standard

    static let idKey = "gcId"
    /// Nanoseconds since the epoch, as a decimal string.
    static let startTimeKey = "gcStartTime"
    /// Milliseconds since the epoch, as a decimal string.
    static let lastActivityKey = "gcLastActivity"
    static let samplingKey = "gcSample"

    static let sessionKeys = [idKey, startTimeKey, lastActivityKey, samplingKey]
}
