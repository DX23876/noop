import Foundation

/// The `coach-state.json` payload inside a `.noopbak` backup.
///
/// The database entry carries every row and `settings.json` carries the whitelisted profile settings, but
/// the Coach keeps its own state outside both: conversations and plans as JSON files in Application
/// Support, memory facts, goals, goal actions, drafted proposals and the coach's identity in UserDefaults.
/// A reinstall restored from a backup therefore came back with a Coach that knew nothing. This entry
/// carries that state.
///
/// Deliberately excluded: data-access consent (a restore onto a new device must never grant access on its
/// own), the provider, model and custom endpoint (the endpoint's auth header can be a secret), API keys
/// (Keychain, never in a backup), usage totals and per-day stamps (restoring a stamp would suppress today's
/// brief or check-in), and the semantic index (rebuilt from the facts).
///
/// Wire form — a JSON object:
///
///     { "format": 1,
///       "files":    { "<file name>": "<base64 bytes>", … },
///       "defaults": "<base64 binary property list of the whitelisted keys>" }
///
/// Defaults travel as a property list so every value keeps its exact type (most are `Data` holding the
/// store's own JSON). Files travel byte-for-byte. Pure codec + file/UserDefaults mapping only; the ZIP
/// container stays in the app's `DataBackup`, so this is testable headlessly
/// (`swift test --filter CoachStateBackupTests`).
public enum CoachStateBackup {

    /// Entry name inside the `.noopbak` ZIP.
    public static let entryName = "coach-state.json"

    /// Written at restore and applied on the next launch, before any Coach store loads — so a store still
    /// holding the old state in memory cannot write it back over the restored files before the relaunch.
    public static let pendingFileName = "coach-state-pending.json"

    /// The wire format this build writes. A payload with a HIGHER format is refused rather than guessed at.
    public static let formatVersion = 1

    /// Application Support files the Coach persists, relative to its store directory.
    public static let fileNames: Set<String> = [
        "coach-conversations.json",
        "coach-plans.json",
    ]

    /// A user-supplied coach avatar photo is `coach-avatar-<UUID>.img` in the same directory; the identity
    /// in UserDefaults refers to it by that file name.
    static let avatarPrefix = "coach-avatar-"
    static let avatarSuffix = ".img"

    /// UserDefaults keys that make up the Coach's state. Restore REPLACES exactly this set: a key present in
    /// the backup is written, a key absent from it is removed.
    public static let defaultsKeys: Set<String> = [
        // Long-term memory.
        "ai.memory.facts",
        // Goals (current + the two legacy keys a pre-multi-goal install still reads), their daily actions,
        // contributions and plan attribution.
        "ai.goals", "ai.goal", "ai.trainingGoal",
        "coach.goalActions.v1", "coach.goalContributions.v1", "coach.goalSetupProposals.v1",
        "coach.planGoalAttribution.v2",
        // Coach-drafted training proposals awaiting review.
        "hevy.routineProposals.v1", "hevy.workoutProposals.v1",
        // Who the coach is and how it talks.
        "coach.identity", "ai.persona", "ai.verbosity", "ai.proactiveLevel", "ai.systemPrompt",
        "ai.allowEmoji",
    ]

    /// The Coach state in memory: file bytes by name, and defaults by key.
    public struct Payload {
        public var files: [String: Data]
        public var defaults: [String: Any]

        public init(files: [String: Data] = [:], defaults: [String: Any] = [:]) {
            self.files = files
            self.defaults = defaults
        }

        public var isEmpty: Bool { files.isEmpty && defaults.isEmpty }
    }

    /// Whether `name` may be read from or written into the Coach directory. A crafted backup must not be
    /// able to name a path outside it, so anything but a known store file or a well-formed avatar name is
    /// refused.
    public static func isAllowedFileName(_ name: String) -> Bool {
        if fileNames.contains(name) { return true }
        guard name.hasPrefix(avatarPrefix), name.hasSuffix(avatarSuffix),
              name.count > avatarPrefix.count + avatarSuffix.count else { return false }
        let middle = name.dropFirst(avatarPrefix.count).dropLast(avatarSuffix.count)
        return middle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Reads the current Coach state from `defaults` and the store `directory`.
    public static func snapshot(defaults: UserDefaults, directory: URL) -> Payload {
        var payload = Payload()
        for key in defaultsKeys {
            if let value = defaults.object(forKey: key) { payload.defaults[key] = value }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where isAllowedFileName(name) {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                payload.files[name] = data
            }
        }
        return payload
    }

    /// Encodes `payload`, or nil when there is nothing to carry (a fresh install then writes no entry).
    public static func encode(_ payload: Payload) -> Data? {
        guard !payload.isEmpty else { return nil }
        let defaults = payload.defaults.filter { defaultsKeys.contains($0.key) }
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: defaults,
                                                              format: .binary, options: 0) else { return nil }
        var files: [String: String] = [:]
        for (name, data) in payload.files where isAllowedFileName(name) {
            files[name] = data.base64EncodedString()
        }
        let object: [String: Any] = [
            "format": formatVersion,
            "files": files,
            "defaults": plist.base64EncodedString(),
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Decodes a `coach-state.json` payload, keeping only whitelisted keys and allowed file names. Returns
    /// nil for anything that is not a payload this build can apply — malformed JSON, a missing part, or a
    /// newer format — so a bad entry leaves the current Coach state alone instead of half-replacing it.
    public static func decode(_ data: Data) -> Payload? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = object["format"] as? Int, format >= 1, format <= formatVersion,
              let rawFiles = object["files"] as? [String: String],
              let rawDefaults = object["defaults"] as? String,
              let plist = Data(base64Encoded: rawDefaults),
              let defaults = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil))
                as? [String: Any] else { return nil }
        var payload = Payload()
        for (name, encoded) in rawFiles where isAllowedFileName(name) {
            guard let bytes = Data(base64Encoded: encoded) else { return nil }
            payload.files[name] = bytes
        }
        payload.defaults = defaults.filter { defaultsKeys.contains($0.key) }
        return payload
    }

    /// Replaces the Coach state with `payload`. Every whitelisted key and every store file is set from the
    /// payload or removed when the payload lacks it, so the result is the backed-up Coach rather than a
    /// blend of two. Avatar photos are only added: an orphaned photo is harmless, while deleting one the
    /// restored identity still names would leave the coach without a face.
    public static func apply(_ payload: Payload, to defaults: UserDefaults, directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in fileNames {
            let url = directory.appendingPathComponent(name)
            if let data = payload.files[name] {
                try data.write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        for (name, data) in payload.files where isAllowedFileName(name) && !fileNames.contains(name) {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        for key in defaultsKeys {
            if let value = payload.defaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Applies a restore left pending in `directory`, if there is one: the current state is first written
    /// beside it as `coach-state-replaced-<stamp>.json` so it can be recovered by hand, then replaced.
    /// Returns true when a pending state was applied. An unreadable pending file is kept for inspection and
    /// the current state is left untouched.
    @discardableResult
    public static func applyPending(defaults: UserDefaults, directory: URL, now: Date = Date()) -> Bool {
        let pending = directory.appendingPathComponent(pendingFileName)
        guard let data = try? Data(contentsOf: pending) else { return false }
        guard let payload = decode(data) else { return false }
        if let previous = encode(snapshot(defaults: defaults, directory: directory)) {
            let stamp = Int(now.timeIntervalSince1970)
            try? previous.write(to: directory.appendingPathComponent("coach-state-replaced-\(stamp).json"),
                                options: .atomic)
        }
        do {
            try apply(payload, to: defaults, directory: directory)
        } catch {
            return false
        }
        try? FileManager.default.removeItem(at: pending)
        return true
    }
}
