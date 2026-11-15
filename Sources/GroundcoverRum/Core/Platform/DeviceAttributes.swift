import Foundation
import UIKit

let sdkName = "groundcover-rum-ios"

/// The SDK's version, as sessions report it. The release sets it.
let sdkVersion = "0.0.1-rc.2"

/// The session envelope's device part, in the React Native SDK's shape (`source`, `os`, `device`,
/// `app`), plus `sdk`, which tells native sessions from RN and Flutter ones under the shared
/// `source`. Read per batch on the core queue. UIKit gives the screen only on the main thread, so
/// each batch asks the main thread to read it again for the next one: a rotation or a Dynamic Type
/// change shows from the batch after it.
final class DeviceAttributes: @unchecked Sendable {
    private let appId: String
    private let version: String?
    private let build: String?
    private let osVersion: String
    private let model: String
    private let readScreen: () -> [String: Any]
    private let onMain: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var screen: [String: Any] = [
        "width": 0.0, "height": 0.0, "scale": 1.0, "fontScale": 1.0,
    ]
    private var refreshQueued = false

    init(
        appId: String, appVersion: String?, appBuild: String?,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        readScreen: @escaping () -> [String: Any] = readMainScreen,
        onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.appId = appId
        self.readScreen = readScreen
        self.onMain = onMain
        // A blank app version or build is left out, as RN omits it.
        version =
            nonBlank(appVersion)
            ?? nonBlank(infoDictionary?["CFBundleShortVersionString"] as? String)
        build = nonBlank(appBuild) ?? nonBlank(infoDictionary?["CFBundleVersion"] as? String)
        // UIDevice's systemVersion, read without UIKit: "17.4", or "17.4.1" with a patch.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion =
            os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"
        let hardware = GCRumDeviceInfo.hardwareModel()
        model = hardware.isEmpty ? "unknown" : hardware
    }

    /// Reads the screen, in points. On the main thread.
    func refreshScreen() {
        let updated = readScreen()
        lock.lock()
        screen = updated
        refreshQueued = false
        lock.unlock()
    }

    func attributes() -> [String: Any] {
        lock.lock()
        let screen = screen
        let queueRefresh = !refreshQueued
        refreshQueued = true
        lock.unlock()
        if queueRefresh { onMain { [weak self] in self?.refreshScreen() } }
        var app: [String: Any] = ["id": appId]
        if let version { app["version"] = version }
        if let build { app["build"] = build }
        return [
            "source": "mobile-rum",
            "os": ["name": "ios", "version": osVersion],
            "device": ["model": model, "brand": "Apple", "screen": screen],
            "app": app,
            "sdk": ["name": sdkName, "version": sdkVersion],
        ]
    }
}

private func nonBlank(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return value
}

/// The main screen, in points, and the Dynamic Type scale. On the main thread.
func readMainScreen() -> [String: Any] {
    let main = UIScreen.main
    return [
        "width": Double(main.bounds.width),
        "height": Double(main.bounds.height),
        "scale": Double(main.scale),
        "fontScale": Double(UIFontMetrics.default.scaledValue(for: 100)) / 100,
    ]
}
