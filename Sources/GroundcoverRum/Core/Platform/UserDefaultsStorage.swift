import Foundation

/// Session state in UserDefaults, in the suite and as the strings the Flutter SDK and the testing
/// hooks use.
final class UserDefaultsStorage: PlatformStorage {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = SessionStorage.defaults) {
        self.defaults = defaults
    }

    func getItem(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func setItem(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    func removeItem(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
