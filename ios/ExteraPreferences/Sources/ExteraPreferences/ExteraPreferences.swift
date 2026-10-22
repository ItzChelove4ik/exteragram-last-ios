import Foundation

/// A typed key and the recovered default of one APK preference.
public struct ExteraPreference<Value: Codable & Equatable & Sendable>: Sendable {
    public let key: String
    public let defaultValue: Value
    let normalize: @Sendable (Value) -> Value

    public init(key: String, defaultValue: Value, normalize: @escaping @Sendable (Value) -> Value = { $0 }) {
        self.key = key
        self.defaultValue = defaultValue
        self.normalize = normalize
    }
}

/// Storage for the future iOS port. Android backup migration is a separate step.
/// Each value uses a namespaced JSON record in the host app's UserDefaults.
/// Mutable cache state is protected by lock. Foundation UserDefaults is safe
/// for concurrent access; no notifications are emitted while holding the lock.
public final class ExteraPreferences: NSObject, @unchecked Sendable {
    public static let standard = ExteraPreferences(defaults: .standard)
    private let defaults: UserDefaults
    private let namespace: String
    private let lock = NSLock()
    private var cache: [String: Any] = [:]

    private struct Cached<Value> {
        let value: Value
    }

    public init(defaults: UserDefaults, namespace: String = "extera.v1") {
        self.defaults = defaults
        self.namespace = namespace
        super.init()
    }

    public func value<Value>(for preference: ExteraPreference<Value>) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[preference.key] as? Cached<Value> {
            return cached.value
        }
        let value: Value
        if let data = defaults.data(forKey: storageKey(preference.key)) {
            do {
                // Use do/catch rather than optional binding so a decoded Optional.none
                // remains a successfully stored value instead of triggering fallback.
                value = preference.normalize(try JSONDecoder().decode(Value.self, from: data))
            } catch {
                value = preference.defaultValue
            }
        } else {
            value = preference.defaultValue
        }
        cache[preference.key] = Cached(value: value)
        return value
    }

    public func set<Value>(_ value: Value, for preference: ExteraPreference<Value>) throws {
        lock.lock()
        var changed = false
        defer {
            lock.unlock()
            if changed {
                NotificationCenter.default.post(name: .exteraPreferencesDidChange, object: self, userInfo: ["key": preference.key])
            }
        }
        if let cached = cache[preference.key] as? Cached<Value>, cached.value == value {
            return
        }
        let data = try JSONEncoder().encode(preference.normalize(value))
        // APK BasePref caches the assigned value before its save implementation
        // sanitizes persistence. Keep that behavior until explicit invalidation.
        cache[preference.key] = Cached(value: value)
        defaults.set(data, forKey: storageKey(preference.key))
        changed = true
    }

    public func reset<Value>(_ preference: ExteraPreference<Value>) {
        lock.lock()
        defer {
            lock.unlock()
            NotificationCenter.default.post(name: .exteraPreferencesDidChange, object: self, userInfo: ["key": preference.key])
        }
        cache.removeValue(forKey: preference.key)
        defaults.removeObject(forKey: storageKey(preference.key))
    }

    /// Re-read persisted storage on the next access, matching APK BasePref.invalidate.
    public func invalidate<Value>(_ preference: ExteraPreference<Value>) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: preference.key)
    }

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    private func storageKey(_ key: String) -> String {
        namespace + "." + key
    }
}

public extension Notification.Name {
    static let exteraPreferencesDidChange = Notification.Name("ExteraPreferencesDidChange")
}
