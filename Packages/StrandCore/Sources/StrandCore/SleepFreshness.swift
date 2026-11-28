import Foundation

/// What the Sleep page says about last night while it is not on screen yet: a sync is running, the night is being
/// worked out, the sync failed, the strap has not synced since the day began, or a sync finished and found no
/// night. Moved out of the iPhone's Sleep screen (`resolveSleepFreshness`) so both phones' Sleep pages state the
/// same thing from the same inputs; the iPhone's Forge page and Android's had no such note at all.
public enum SleepFreshness {
    public enum Status: String, Codable, Equatable, Sendable {
        case syncing, calculating, syncFailed, awaitingSync, notDetected
    }

    /// Pure priority ladder behind the Sleep status note. "Missing" is deliberately held until morning so
    /// opening Sleep during the night does not claim a still-in-progress night was missed.
    public static func resolve(hasCurrentNight: Bool, morningReady: Bool, syncing: Bool,
                               calculating: Bool, syncedSinceDayStart: Bool,
                               syncFailed: Bool) -> Status? {
        if syncing { return .syncing }
        // #2108: a night already in hand outranks .calculating. It used to sit below, so `hasCurrentNight`
        // could only silence the missing-night states and a finished night was structurally unable to
        // silence this one: the banner said "detecting and staging the night now" directly above that same
        // night scored, timed and staged on screen. .syncing stays above, because data still arriving can
        // genuinely change what is shown.
        if hasCurrentNight { return nil }
        if calculating { return .calculating }
        if !morningReady { return nil }
        if syncFailed { return .syncFailed }
        return syncedSinceDayStart ? .notDetected : .awaitingSync
    }

    /// The same ladder from what a page holds: the latest night's wake time, the clock, and the strap's state.
    /// The current night is one that ended today; morning starts at six; `lastSyncedAt` is unix seconds.
    public static func resolve(latestWakeTs: Int?, now: Date, calendar: Calendar = .current, syncing: Bool,
                               calculating: Bool, lastSyncedAt: Double?, syncFailed: Bool) -> Status? {
        let start = calendar.startOfDay(for: now)
        let current = latestWakeTs.map {
            calendar.isDate(Date(timeIntervalSince1970: TimeInterval($0)), inSameDayAs: now)
        } ?? false
        return resolve(hasCurrentNight: current, morningReady: calendar.component(.hour, from: now) >= 6,
                       syncing: syncing, calculating: calculating,
                       syncedSinceDayStart: (lastSyncedAt ?? 0) >= start.timeIntervalSince1970,
                       syncFailed: syncFailed)
    }
}
