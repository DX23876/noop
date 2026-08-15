import Foundation

/// Who has had today's brief, and whether the numbers behind it have since changed.
///
/// Three flags that used to be one bare UserDefaults read inside `startBriefIfNeeded`, pulled out
/// because a user report turned the day-stamp from bookkeeping into a decision:
///
/// > "the automatically assumed wake up time will incorrectly say i woke up far far earlier than i
/// > actually did and my recovery metrics will therefore be way off. The AI coach will give me my daily
/// > plan based on this before I manually edit the sleep time"
///
/// Two separate faults hide in that sentence. The brief runs on a night that has not settled yet — and
/// then, because the day was stamped, correcting the sleep by hand leaves the WRONG brief standing for
/// the rest of the day. Both are handled here rather than in the middle of the send path:
///
///  * a brief withheld for an unsettled night does not stamp the day, so it happens for real later;
///  * a hand-correction to last night clears the stamp AND raises a "stale" mark, which is what lets
///    the re-run bypass the second gate (`startBriefIfNeeded` also refuses when the active thread
///    already has today's messages — the brief it is trying to replace).
///
/// Pure UserDefaults + injectable clock so the day arithmetic is testable without waiting for 4 a.m.
/// `@MainActor` because the logical-day helper it reasons in is, and every caller (the Sleep editor's
/// save handlers, the brief gate) is already on the main actor anyway.
@MainActor
enum CoachBriefStamp {

    /// The logical day the last brief was generated on.
    static let lastBriefDayKey = "ai.lastBriefDay"
    /// The logical day on which a sleep correction invalidated that brief.
    static let staleAfterSleepEditKey = "ai.briefStaleAfterSleepEdit"
    /// The logical day on which the user vouched for the detected wake time.
    static let wakeConfirmedDayKey = "ai.wakeConfirmedDay"

    // MARK: - Reads

    static func lastBriefDay(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastBriefDayKey)
    }

    /// True when today's brief has been invalidated by a correction and should be re-run even though a
    /// brief already exists in this thread.
    static func isStale(today: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: staleAfterSleepEditKey) == today
    }

    // MARK: - Writes

    static func stamp(day: String, defaults: UserDefaults = .standard) {
        defaults.set(day, forKey: lastBriefDayKey)
    }

    /// The user said the detected wake time is right. Their word outranks the heuristic for the rest of
    /// the day: they were there, and the gate exists to protect them from a wrong number, not to make
    /// them argue with one.
    static func confirmWake(day: String, defaults: UserDefaults = .standard) {
        defaults.set(day, forKey: wakeConfirmedDayKey)
    }

    static func wakeConfirmed(today: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: wakeConfirmedDayKey) == today
    }

    static func clearStale(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: staleAfterSleepEditKey)
    }

    /// A night was hand-corrected (edited, deleted, or a nap added). When it belongs to the CURRENT
    /// logical day, drop the day-stamp and mark the brief stale so the next open regenerates it against
    /// the corrected recovery.
    ///
    /// Scoped to today on purpose: fixing a night from last week changes that week's history, not the
    /// plan for this morning, and re-briefing for it would be noise.
    ///
    /// - Parameter wakeTs: the corrected night's wake time (unix seconds). For a delete, the window's
    ///   end; for a nap, its end. Whatever the user just moved.
    @discardableResult
    static func invalidateAfterSleepCorrection(wakeTs: Int,
                                               now: Date = Date(),
                                               defaults: UserDefaults = .standard) -> Bool {
        let today = Repository.logicalDayKey(now)
        let nightDay = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(wakeTs)))
        guard nightDay == today else { return false }
        defaults.removeObject(forKey: lastBriefDayKey)
        defaults.set(today, forKey: staleAfterSleepEditKey)
        return true
    }
}
