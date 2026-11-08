import Foundation

/// The storage a host provides. Synchronous: session state is read while the pipeline is built and
/// on hot paths.
protocol PlatformStorage: AnyObject {
    func getItem(_ key: String) throws -> String?
    func setItem(_ key: String, _ value: String) throws
    func removeItem(_ key: String) throws
}

/// A ``PlatformStorage`` that never throws. Storage fails in normal operation (a full disk, a
/// broken backend): reads degrade to nil or a fallback, and writes are dropped, never surfaced to
/// the host app.
struct SafeStorage {
    private let storage: PlatformStorage?

    init(_ storage: PlatformStorage?) {
        self.storage = storage
    }

    func getItem(_ key: String) -> String? {
        do {
            return try storage?.getItem(key)
        } catch {
            handleError(error)
            return nil
        }
    }

    func setItem(_ key: String, _ value: String) {
        do {
            try storage?.setItem(key, value)
        } catch {
            handleError(error)
        }
    }

    func removeItem(_ key: String) {
        do {
            try storage?.removeItem(key)
        } catch {
            handleError(error)
        }
    }

    /// The stored value as a whole number, exact for nanoseconds, or `fallback` when it is missing
    /// or not a finite number. A fraction is dropped.
    func getIntegerItem(_ key: String, fallback: Int64 = 0) -> Int64 {
        guard let raw = getItem(key)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return fallback
        }
        if let exact = Int64(raw) { return exact }
        guard let number = Double(raw), number.isFinite,
            let whole = Int64(exactly: number.rounded(.towardZero))
        else { return fallback }
        return whole
    }
}
