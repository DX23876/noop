import Foundation

/// What the last Hevy sync did, kept so the user can see whether their strength data is current.
///
/// The shared engine keeps its banked frontier and backfill-completion marker in the database.
/// UserDefaults holds presentation status only and cannot advance an import past unbanked pages.
struct HevySyncStatus: Equatable {
    /// When a sync last completed without error.
    var lastSuccess: Date?
    /// The last failure, still shown after a later success only if that success has not happened yet.
    var lastError: String?
    /// Workouts stored locally at the end of the last run.
    var storedWorkouts: Int
    /// Documents (or sets) the parser had to drop across the last run. Surfaced rather than swallowed:
    /// a tolerant parser that never reports what it discarded is indistinguishable from a broken one.
    var skipped: Int

    static let empty = HevySyncStatus(lastSuccess: nil, lastError: nil, storedWorkouts: 0, skipped: 0)
}

/// Persistence for `HevySyncStatus` plus the "does the user want this at all" switch.
///
/// UserDefaults rather than the database on purpose: this is app state, not the user's health data, and
/// it must survive a "delete all Hevy data" without being part of what gets deleted.
enum HevySyncState {

    /// The master switch. **Default off.** Until someone deliberately connects Hevy, the app should
    /// neither show the surface nor make a network request — same posture as `CoachFeaturePrefs`.
    static let enabledKey = "hevy.enabled"
    private static let lastSuccessKey = "hevy.lastSuccess"
    private static let lastErrorKey = "hevy.lastError"
    private static let storedWorkoutsKey = "hevy.storedWorkouts"
    private static let skippedKey = "hevy.lastSkipped"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func load(_ defaults: UserDefaults = .standard) -> HevySyncStatus {
        HevySyncStatus(
            lastSuccess: defaults.object(forKey: lastSuccessKey) as? Date,
            lastError: defaults.string(forKey: lastErrorKey),
            storedWorkouts: defaults.integer(forKey: storedWorkoutsKey),
            skipped: defaults.integer(forKey: skippedKey))
    }

    static func recordSuccess(storedWorkouts: Int, skipped: Int,
                              at date: Date = Date(), _ defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastSuccessKey)
        defaults.set(storedWorkouts, forKey: storedWorkoutsKey)
        defaults.set(skipped, forKey: skippedKey)
        // A success clears the previous failure: leaving a stale error under a fresh timestamp reads
        // as "it is still broken", which would be a lie about the current state.
        defaults.removeObject(forKey: lastErrorKey)
    }

    static func recordFailure(_ message: String, _ defaults: UserDefaults = .standard) {
        defaults.set(message, forKey: lastErrorKey)
    }

    /// Forget everything this lane remembers. Paired with `WhoopStore.deleteAllHevyData` and a
    /// Keychain clear, so "disconnect and remove" leaves nothing behind.
    static func reset(_ defaults: UserDefaults = .standard) {
        for key in [enabledKey, "hevy.catalogueSyncedAt", lastSuccessKey,
                    lastErrorKey, storedWorkoutsKey, skippedKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
