import Foundation

/// The existing goals format uses property-list values. Apple keeps UserDefaults; Android supplies
/// an in-memory transaction image and commits its goals.bundle through the shared SQLite store.
protocol GoalPreferenceStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func dictionaryRepresentation() -> [String: Any]
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func array(forKey key: String) -> [Any]?
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
}

extension UserDefaults: GoalPreferenceStorage {}

/// All goal stores in one app session resolve preferences through the same backing image. Changing
/// this binding is reserved for the core host while opening or restoring its single active session.
enum GoalPreferences {
    #if os(Android)
    nonisolated(unsafe) static var standard: any GoalPreferenceStorage = GoalPreferenceImage()
    #else
    nonisolated(unsafe) static var standard: any GoalPreferenceStorage = UserDefaults.standard
    #endif
}

/// A Foundation-compatible property-list image. No operating-system defaults file or side database
/// is created by the Android core; its host can reject a failed commit before publishing new state.
final class GoalPreferenceImage: GoalPreferenceStorage {
    private let lock = NSLock()
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) { self.values = values }
    enum DecodeError: Error { case invalidImage }
    convenience init(serialized data: Data?) throws {
        guard let data else { self.init(); return }
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw DecodeError.invalidImage }
        self.init(values)
    }
    func serialized() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionaryRepresentation(), format: .binary, options: 0)
    }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    func removeObject(forKey key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
    func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? {
        let value = object(forKey: key)
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
    func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func bool(forKey key: String) -> Bool {
        let value = object(forKey: key)
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return false }
        return ["true", "yes", "1"].contains(string.lowercased())
    }
    func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        return (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0
    }
    func double(forKey key: String) -> Double {
        let value = object(forKey: key)
        return (value as? NSNumber)?.doubleValue ?? (value as? NSString)?.doubleValue ?? 0
    }
}
