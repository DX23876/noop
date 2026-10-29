import Foundation

/// The settings the Android Settings pages share with the core's own UserDefaults (Android parity plan 2.3): goal
/// limits, rest days and the step goal that goals and Momentum read, and the training defaults a new session takes.
/// Only these keys can be read or written, each with the type and range Apple's settings screens allow.
enum CorePrefs {
    private enum Kind { case int(ClosedRange<Int>), bool, weekdays, string(Set<String>) }

    private static let keys: [String: Kind] = [
        "goals.limit.longTerm": .int(1...10),
        "goals.limit.period": .int(1...12),
        "training.restWeekdays": .weekdays,
        "momentum.stepGoal": .int(0...30_000),
        "goals.motivation.enabled": .bool,
        "goals.todayInviteDismissed": .bool,
        "goals.introSeen": .bool,
        "training.newExerciseSets": .int(1...6),
        "training.defaultRestSeconds": .int(0...600),
        "training.warmupRestSeconds": .int(0...300),
        "training.weightUnit": .string(["kilograms", "pounds"]),
        "training.effortScale": .string(["off", "rir", "rpe"]),
    ]

    /// The stored values of the known keys; a key never set is left out, so the caller keeps its default.
    static func read() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys.keys {
            if let value = UserDefaults.standard.object(forKey: key) { out[key] = value }
        }
        return out
    }

    static func readJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: read()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes one known key; anything else, or a value out of its range, is refused.
    static func write(key: String, value: Any?) -> Bool {
        guard let kind = keys[key] else { return false }
        switch kind {
        case .int(let range):
            guard let n = (value as? NSNumber)?.intValue, range.contains(n) else { return false }
            UserDefaults.standard.set(n, forKey: key)
        case .bool:
            guard let b = (value as? Bool) ?? (value as? NSNumber)?.boolValue else { return false }
            UserDefaults.standard.set(b, forKey: key)
        case .weekdays:
            guard let days = value as? [Any] else { return false }
            let clean = Set(days.compactMap { ($0 as? NSNumber)?.intValue }.filter { (1...7).contains($0) })
            UserDefaults.standard.set(clean.sorted(), forKey: key)
        case .string(let allowed):
            guard let s = value as? String, allowed.contains(s) else { return false }
            UserDefaults.standard.set(s, forKey: key)
        }
        return true
    }
}
