import UIKit

/// The app's foreground state, mapped as the Flutter SDK maps it: inactive persists activity;
/// entering the background persists it and flushes, once per departure; becoming active again after
/// the app was shown, or after it entered the background, is a return, and a return is presence.
/// The launch is none of these, so an app nobody touches sends nothing: any state but active when
/// the SDK starts (a scene-based app reads background in didFinishLaunching) is neither.
struct LifecycleMapper {
    private var shown: Bool
    private var away = false

    init(initialState: UIApplication.State) {
        shown = initialState == .active
    }

    mutating func didBecomeActive() -> HostLifecycle? {
        let returning = shown || away
        away = false
        shown = true
        return returning ? .foreground : nil
    }

    func willResignActive() -> HostLifecycle? {
        .inactive
    }

    mutating func didEnterBackground() -> HostLifecycle? {
        guard !away else { return nil }
        away = true
        return .background
    }
}

/// Watches the app's notifications and reports each transition the mapper keeps. Main thread only.
final class HostLifecycleObserver {
    private var mapper: LifecycleMapper
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(
        initialState: UIApplication.State, center: NotificationCenter = .default,
        report: @escaping (HostLifecycle) -> Void
    ) {
        mapper = LifecycleMapper(initialState: initialState)
        self.center = center
        tokens = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                if let state = self?.mapper.didBecomeActive() { report(state) }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in
                if let state = self?.mapper.willResignActive() { report(state) }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in
                if let state = self?.mapper.didEnterBackground() { report(state) }
            },
        ]
    }

    func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }
}
