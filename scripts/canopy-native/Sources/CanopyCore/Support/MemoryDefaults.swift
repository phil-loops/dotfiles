import Foundation

/// UserDefaults that live in memory only: the practice app's remembered face and unsent words, and
/// every test's app — nothing a test writes reaches the machine's preferences.
public final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    public convenience init() { self.init(suiteName: "canopy-native.memory")! }

    override public func dictionaryRepresentation() -> [String: Any] { values }
    override public func object(forKey key: String) -> Any? { values[key] }
    override public func set(_ value: Any?, forKey key: String) { values[key] = value }
    override public func removeObject(forKey key: String) { values[key] = nil }
    override public func string(forKey key: String) -> String? { values[key] as? String }
}
