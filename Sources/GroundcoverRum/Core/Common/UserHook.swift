import Foundation

/// The app's own callbacks, run inside the SDK: beforeSend, enrichEvent and the redact hook. What
/// one sends through the SDK's API while it runs is a side effect of the SDK sending something, so
/// the API drops it: sent, it would go through the same hook again.
enum UserHook {
    private static let depthKey = "com.groundcover.rum.userHookDepth"

    /// Whether one of the app's hooks is running on this thread.
    static var isRunning: Bool { depth > 0 }

    static func run<T>(_ hook: () throws -> T) rethrows -> T {
        depth += 1
        defer { depth -= 1 }
        return try hook()
    }

    private static var depth: Int {
        get { Thread.current.threadDictionary[depthKey] as? Int ?? 0 }
        set { Thread.current.threadDictionary[depthKey] = newValue == 0 ? nil : newValue }
    }
}
