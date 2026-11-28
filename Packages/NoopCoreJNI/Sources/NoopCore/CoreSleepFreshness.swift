import Foundation
import StrandCore

/// `sleep.freshness`: the note the Sleep page shows while last night is not on screen yet, decided by the shared
/// `SleepFreshness` and worded as the iPhone's `SleepFreshnessNote` words it, so Android says the same thing.
enum CoreSleepFreshness {
    struct Note: Encodable, Equatable {
        /// `SleepFreshness.Status`'s raw value, or nil when the page needs no note.
        var status: String?
        var title: String
        var message: String
    }

    static func run(_ args: [String: Any]) -> String {
        func bool(_ key: String) -> Bool { args[key] as? Bool ?? false }
        let wake = (args["latestWakeTs"] as? NSNumber)?.intValue
        let synced = (args["lastSyncedAt"] as? NSNumber)?.doubleValue
        let now = (args["now"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let status = SleepFreshness.resolve(latestWakeTs: wake, now: now, syncing: bool("syncing"),
                                            calculating: bool("calculating"), lastSyncedAt: synced,
                                            syncFailed: bool("syncFailed"))
        return CoreRead.json(note(status, chunks: (args["chunks"] as? NSNumber)?.intValue ?? 0))
    }

    /// The words for each state, the iPhone's own.
    static func note(_ status: SleepFreshness.Status?, chunks: Int) -> Note {
        switch status {
        case .syncing:
            return Note(status: status?.rawValue, title: String(localized: "Syncing strap history…"),
                        message: chunks > 0 ? String(localized: "\(chunks) chunks pulled") : "")
        case .calculating:
            return Note(status: status?.rawValue, title: String(localized: "Calculating last night's sleep…"),
                        message: String(localized: "Your strap history is in. NOOP is detecting and staging the night now."))
        case .syncFailed:
            return Note(status: status?.rawValue, title: String(localized: "Last night's sleep hasn't synced"),
                        message: String(localized: "The history sync stopped before it finished. Keep the strap nearby and try Sync again."))
        case .awaitingSync:
            return Note(status: status?.rawValue, title: String(localized: "Waiting for last night's sleep"),
                        message: String(localized: "Connect the strap and sync its history. NOOP will calculate the night when the overnight data arrives."))
        case .notDetected:
            return Note(status: status?.rawValue, title: String(localized: "Last night's sleep wasn't detected"),
                        message: String(localized: "Sync finished, but NOOP couldn't confidently identify a sleep window. Keep the strap connected and try Sync again; the older night below is still your latest detected sleep."))
        case nil:
            return Note(status: nil, title: "", message: "")
        }
    }
}
