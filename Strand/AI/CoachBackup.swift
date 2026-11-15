import Foundation

/// The coach's own state inside a `.noopbak`, as an optional entry of its own beside `settings.json`.
///
/// Until this existed a device migration restored every health row and lost most of the coach: who it
/// is, how it speaks, the facts it has remembered, the plan book, the digests of past conversations and
/// every consent it had been given. For the one feature whose whole value is what it has learned about
/// someone over months, that is the worst thing in the file to drop.
///
/// **Why an entry of its own and not `settings.json`.** That file is a cross-platform whitelist
/// (`BackupSettings`), and a `.noopbak` has to keep moving between this fork and `ryanbr/noop` in both
/// directions. New keys there would make the two disagree about a shared file. A new entry does not:
/// the archive skips entries it does not recognise, so upstream reads a fork backup exactly as it
/// always did, and a backup written by upstream simply carries no `coach.json` — in which case the
/// local coach is left alone rather than cleared.
///
/// **What it is NOT.** `settings.json` is documented as safe to attach to a GitHub issue. This is not:
/// it carries remembered facts, which are about the person. It travels inside a backup that already
/// holds the whole health database, so it adds no new class of sensitivity, but nobody should later
/// mistake it for something shareable.
///
/// **What it deliberately leaves out.** API keys (the Keychain, never a file), the Custom provider's
/// base URL and auth header (a local URL can name a home network), the selected model and the role
/// models (provider-specific, and a restore may land on another provider), every `last…Day` scheduling
/// stamp and the usage counters (about this install's clock, not the person), the settings page's own
/// section layout, the derived semantic index (rebuildable), the chat messages themselves (the thread
/// DIGESTS travel, the transcripts do not), and the master switch `coach.featureEnabled`: a restore
/// must never switch on a coach the wearer has not switched on, which is also what makes carrying the
/// consents below safe, since nothing can be sent while the coach is off.
///
/// **It carries no key the goals bundle already carries.** `GoalBackupBundle` puts the goals system
/// into `settings.json` under one whitelisted key. A value that travelled in both places could come
/// back differently depending on which was applied last, so the two lists are disjoint and a test
/// holds them that way.
enum CoachBackup {

    /// Canonical entry name inside the `.noopbak` ZIP.
    static let entryName = "coach.json"

    /// Payload version. Absent or unknown means the payload is ignored rather than guessed at.
    static let version = 1

    // MARK: - The allowlist

    /// Plain `UserDefaults` values carried verbatim, by storage key. Listed one by one rather than
    /// swept by prefix: `ai.` and `coach.` also hold the base URL, the scheduling stamps, the usage
    /// counters and this device's layout, none of which belong in a backup.
    static let carriedKeys: [String] = [
        // Who the coach is and how it speaks.
        "coach.identity", "ai.persona", "ai.verbosity", "ai.allowEmoji", "ai.proactiveLevel",
        "ai.autoSummarize", "ai.systemPrompt",
        // What it is allowed to see. Safe to carry because the master switch is not carried.
        "ai.dataConsent", "ai.toolConsent", "ai.includeOnDeviceSignals",
        "coach.semanticMemory.enabled",
        // What it has learned and agreed, minus everything `GoalBackupBundle` already carries.
        "ai.memory.facts", "ai.goal", "ai.trainingGoal",
        "coach.goalSetupProposals.v1", "coach.planGoalAttribution.v2"
    ]

    /// Application Support files carried verbatim, by file name. The live transcript
    /// (`coach-transcript.json`) and the conversation file are deliberately not among them: the
    /// conversations travel as digests below.
    static let carriedFiles: [String] = ["coach-plans.json"]

    // MARK: - Snapshot

    /// This device's coach state as the `coach.json` payload, or nil when there is nothing to carry.
    /// A fresh install then writes a backup with no coach entry at all, which is the same right
    /// degrade `settings.json` makes.
    ///
    /// Reads the raw blobs rather than going through `CoachMemory`, `CoachPlanStore` or the identity
    /// store, all of which are `@MainActor`, because the export runs detached. `defaults` and
    /// `supportDirectory` are arguments so the round trip is testable without touching the wearer's own
    /// settings or files.
    static func snapshot(defaults: UserDefaults = .standard,
                         supportDirectory: URL? = applicationSupportDirectory()) -> Data? {
        var payload: [String: Any] = ["v": version]

        var values: [String: Any] = [:]
        for key in carriedKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            values[key] = encodeValue(raw)
        }
        if !values.isEmpty { payload["defaults"] = values }

        if let supportDirectory {
            var files: [String: String] = [:]
            for name in carriedFiles {
                guard let data = try? Data(contentsOf: supportDirectory.appendingPathComponent(name))
                else { continue }
                files[name] = data.base64EncodedString()
            }
            if !files.isEmpty { payload["files"] = files }
        }

        let digests = conversationDigests(supportDirectory: supportDirectory)
        if !digests.isEmpty { payload["threadDigests"] = digests }

        guard payload.count > 1 else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Apply

    /// Write a decoded payload into this device. Best-effort throughout: an unreadable or
    /// unknown-version payload applies nothing and can never fail a restore, and a key the payload
    /// does not carry is left exactly as it was, so restoring a backup without a `coach.json` leaves
    /// the coach alone instead of wiping it.
    static func apply(_ data: Data,
                      defaults: UserDefaults = .standard,
                      supportDirectory: URL? = applicationSupportDirectory()) {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (payload["v"] as? Int) == version else { return }

        if let values = payload["defaults"] as? [String: Any] {
            // Driven by `carriedKeys`, never by the payload's own key list, so a hand-edited file
            // cannot write a key this does not carry.
            for key in carriedKeys {
                guard let raw = values[key], let decoded = decodeValue(raw) else { continue }
                defaults.set(decoded, forKey: key)
            }
        }

        // Created up front: a restore may land on an install whose Application Support folder does not
        // exist yet, and both the files and the thread digests write into it.
        if let supportDirectory {
            try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }

        if let supportDirectory, let files = payload["files"] as? [String: String] {
            for name in carriedFiles {
                guard let encoded = files[name], let data = Data(base64Encoded: encoded) else { continue }
                try? data.write(to: supportDirectory.appendingPathComponent(name))
            }
        }

        if let digests = payload["threadDigests"] as? [[String: Any]] {
            restoreDigests(digests, supportDirectory: supportDirectory)
        }
    }

    // MARK: - Applied on the next launch, never into the running process

    // A restore must not write the coach's state into a running app. The app asks the wearer to quit
    // and reopen, but it keeps running until they do, and every coach store still holds its OLD state
    // in memory: the conversation list saves itself shortly after any change, and the fact memory, the
    // plan book and the identity each write their whole blob on the next edit. Any of those, in that
    // window, would put the pre-restore state back over what had just been restored.
    //
    // So a restore only STAGES the payload and the next launch applies it, from the app's own start,
    // before a coach store exists to overwrite it. That is also when the restored database takes
    // effect, so the coach and the data it reasons about change over at the same moment, and it holds
    // for every store added later without each one having to know that restores exist.

    /// The staged payload's file name, beside the coach's other files.
    static let stagedFileName = "coach-restore-pending.json"

    /// Stage `data` for the next launch, or clear a staged payload when `data` is nil or unusable.
    ///
    /// The last restore wins. Restoring a backup WITHOUT a coach entry clears an earlier pending
    /// payload rather than leaving it to land on top of the database this restore just put in place.
    /// The coach's own state is never cleared by that; only a payload that had not been applied yet.
    static func stage(_ data: Data?, supportDirectory: URL?) {
        guard let supportDirectory else { return }
        let url = supportDirectory.appendingPathComponent(stagedFileName)
        guard let data, isApplicable(data) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Apply a staged payload, then remove it. Called once at launch, before the coach stores are built.
    ///
    /// Apply first, delete second: if the process dies in between, the next launch applies it again,
    /// which is harmless, because every step of `apply` is an overwrite and the digests are
    /// deduplicated. Returns whether anything was applied.
    @discardableResult
    static func applyStagedRestoreIfPresent(defaults: UserDefaults = .standard,
                                            supportDirectory: URL? = applicationSupportDirectory()) -> Bool {
        guard let supportDirectory else { return false }
        let url = supportDirectory.appendingPathComponent(stagedFileName)
        guard let data = try? Data(contentsOf: url) else { return false }
        apply(data, defaults: defaults, supportDirectory: supportDirectory)
        try? FileManager.default.removeItem(at: url)
        return true
    }

    /// Whether `data` is a payload this build knows how to apply.
    static func isApplicable(_ data: Data) -> Bool {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (payload["v"] as? Int) == version
    }

    // MARK: - Thread digests

    /// One past conversation distilled: its title, the summary the maintainer wrote, and when it was
    /// last touched. The MESSAGES are deliberately not carried. A backup that quoted every chat
    /// verbatim would be a different object from one that carries what the coach learned.
    ///
    /// Restored as archived conversations with no messages, which is what makes them work: the
    /// cross-conversation digest feeds on `summary` and picks them up, `threadsIndex` filters on a
    /// non-empty message list and leaves them out, and the history screen keeps them in its own
    /// Archived section instead of showing a list of rows with nothing in them.
    static func conversationDigests(supportDirectory: URL?) -> [[String: Any]] {
        guard let supportDirectory,
              let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("coach-conversations.json")),
              let conversations = try? JSONDecoder().decode([CoachConversation].self, from: data)
        else { return [] }
        return conversations.compactMap { convo in
            guard let summary = convo.summary, !summary.isEmpty else { return nil }
            return [
                "title": convo.title,
                "summary": summary,
                "updatedAt": convo.updatedAt.timeIntervalSince1970
            ]
        }
    }

    /// Merge restored digests into whatever conversations this device already has, newest first. A
    /// digest whose summary is already present is skipped, so restoring the same backup twice does not
    /// double the list.
    static func restoreDigests(_ digests: [[String: Any]], supportDirectory: URL?) {
        guard let supportDirectory else { return }
        let url = supportDirectory.appendingPathComponent("coach-conversations.json")
        var existing: [CoachConversation] = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([CoachConversation].self, from: $0) } ?? []
        let known = Set(existing.compactMap(\.summary))

        for digest in digests {
            guard let summary = digest["summary"] as? String, !summary.isEmpty,
                  !known.contains(summary) else { continue }
            var restored = CoachConversation(title: digest["title"] as? String ?? "", archived: true)
            restored.summary = summary
            if let stamp = digest["updatedAt"] as? Double {
                restored.updatedAt = Date(timeIntervalSince1970: stamp)
            }
            existing.append(restored)
        }
        existing.sort { $0.updatedAt > $1.updatedAt }
        guard let data = try? JSONEncoder().encode(existing) else { return }
        try? data.write(to: url)
    }

    // MARK: - Where the files are, and how a value travels

    /// The app's Application Support directory, built exactly as `CoachTranscriptStore` and
    /// `CoachSemanticMemory` build it, so all three name the same folder.
    static func applicationSupportDirectory() -> URL? {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
    }

    /// JSON carries neither `Data` nor a typed array, and the coach stores both (the encoded fact list,
    /// the consent set). Each value therefore travels tagged with its kind, so `apply` puts back the
    /// same type `UserDefaults` handed over rather than a String that decodes to nothing.
    static func encodeValue(_ raw: Any) -> Any {
        switch raw {
        case let data as Data:      return ["kind": "data", "value": data.base64EncodedString()]
        case let value as Bool:     return ["kind": "bool", "value": value]
        case let value as Int:      return ["kind": "int", "value": value]
        case let value as Double:   return ["kind": "double", "value": value]
        case let value as String:   return ["kind": "string", "value": value]
        case let value as [String]: return ["kind": "stringArray", "value": value]
        default:                    return ["kind": "unsupported"]
        }
    }

    static func decodeValue(_ raw: Any) -> Any? {
        guard let box = raw as? [String: Any], let kind = box["kind"] as? String else { return nil }
        switch kind {
        case "data":        return (box["value"] as? String).flatMap { Data(base64Encoded: $0) }
        // `NSNumber` bridges a JSON bool and a JSON number identically, so the tag, not the runtime
        // type, decides which one goes back. Without it a `false` could return as `0`.
        case "bool":        return (box["value"] as? NSNumber)?.boolValue
        case "int":         return (box["value"] as? NSNumber)?.intValue
        case "double":      return (box["value"] as? NSNumber)?.doubleValue
        case "string":      return box["value"] as? String
        case "stringArray": return box["value"] as? [String]
        default:            return nil
        }
    }
}
