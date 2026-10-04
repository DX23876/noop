import Foundation

/// Packs the whole goals system into one string for the `.noopbak` settings payload, and unpacks it on
/// restore.
///
/// Goal state lives in several UserDefaults values: the long-term goals, the daily goals and their
/// check-offs, the workout attributions, the weekly and monthly goals with their frozen results, and the
/// goal preferences (order, limits, rest days, hints already shown). None of it was in the backup, so a
/// restore onto a new phone silently lost every goal and its history. The settings wire carries only
/// Int, Double and String, so each value travels as a base64 binary property list inside one JSON object
/// under the whitelisted `goals.bundle` key.
///
/// Pure apart from the `UserDefaults` it is handed, so the round trip is testable with a suite.
enum GoalBackupBundle {
    static let settingsKey = "goals.bundle"
    static let version = 1

    /// The goal keys that predate the `goals.` prefix. Literals rather than the stores' own constants:
    /// those stores are main-actor isolated and the backup export runs off the main actor.
    static let fixedKeys = ["ai.goals", "coach.goalActions.v1", "coach.goalContributions.v1",
                            "training.restWeekdays", "momentum.stepGoal"]

    /// Every key that belongs to the goals system: the explicit stores plus anything under `goals.`.
    static func keys(in defaults: UserDefaults) -> [String] {
        let fixed = fixedKeys
        let prefixed = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("goals.") && $0 != settingsKey }
        return Array(Set(fixed + prefixed)).sorted()
    }

    /// The bundle as a JSON string, or nil when no goal state exists yet.
    static func encode(from defaults: UserDefaults) -> String? {
        var entries: [String: String] = [:]
        for key in keys(in: defaults) {
            guard let value = defaults.object(forKey: key),
                  let data = try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary,
                                                                 options: 0)
            else { continue }
            entries[key] = data.base64EncodedString()
        }
        guard !entries.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: ["v": version, "entries": entries],
                                                     options: [.sortedKeys]) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    /// Writes the bundle's values back. A malformed bundle or a single unreadable entry restores fewer
    /// values, never fails the restore. Returns the number of values written.
    @discardableResult
    static func apply(_ bundle: String, to defaults: UserDefaults) -> Int {
        guard let data = bundle.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [String: String] else { return 0 }
        var written = 0
        for (key, encoded) in entries {
            // Only goal keys come back, whatever the file claims to contain.
            guard key.hasPrefix("goals.") || fixedKeys.contains(key),
                  let plist = Data(base64Encoded: encoded),
                  let wrapped = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [Any],
                  let value = wrapped.first else { continue }
            defaults.set(value, forKey: key)
            written += 1
        }
        return written
    }
}
