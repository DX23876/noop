import Foundation

/// The repeat-guards behind the coach's two goal-driven proactive messages: the deadline nudge
/// (`AICoachEngine.runProactiveNudgeIfNeeded`) and the expiry look-back
/// (`AICoachEngine.runGoalReviewIfNeeded`). One tiny type rather than string literals at the call
/// sites, because the same keys now have to be readable from `CoachGoalStore.remove(_:)` too.
///
/// The stamp records WHICH TARGET DATE was spoken about, not the day it was spoken.
///
/// That distinction is the whole point. Storing "the day I nudged" made these guards permanent: the
/// review itself invites the user to *"extend it, adjust the target, mark it done, or let it go"*, and
/// a user who extended the date got silence at the new one — the stamp was still set, so neither the
/// deadline nudge nor the review ever fired again. Keying on the target date makes the guard
/// self-healing: a moved date is a different key, which re-arms both without anyone having to
/// remember to clear anything. A date that has NOT moved still stamps exactly once, which is what the
/// guard was for.
///
/// Deliberately no migration: a stamp written under the old scheme holds a day key that no target date
/// will match, so it simply reads as "not yet nudged for this date". One extra nudge per goal after
/// the update, on a goal whose deadline is genuinely live — that is closer to right than the silence
/// it replaces.
@MainActor
enum CoachGoalNudgeStamps {

    /// The deadline nudge fires at most once per goal per band (8-14 days out, then ≤7 days out), so
    /// the band is part of the key.
    static func deadlineKey(goalId: UUID, important: Bool) -> String {
        "coach.goalDeadlineNudged.\(goalId.uuidString).\(important ? "7" : "14")"
    }

    static func reviewKey(goalId: UUID) -> String {
        "coach.goalReviewed.\(goalId.uuidString)"
    }

    /// The stamp VALUE for a goal: its target date as a plain day key, or nil for a goal without one
    /// (which can neither have a deadline nudge nor an expiry review, so it is never stamped).
    static func stampValue(for goal: CoachGoal) -> String? {
        goal.targetDate.map { Repository.localDayKey($0) }
    }

    /// Whether this goal has already been spoken about AT ITS CURRENT TARGET DATE.
    static func alreadyFired(_ key: String, for goal: CoachGoal,
                             defaults: UserDefaults = .standard) -> Bool {
        guard let value = stampValue(for: goal) else { return false }
        return defaults.string(forKey: key) == value
    }

    static func stamp(_ key: String, for goal: CoachGoal, defaults: UserDefaults = .standard) {
        guard let value = stampValue(for: goal) else { return }
        defaults.set(value, forKey: key)
    }

    /// Drop every stamp belonging to a goal. Only `CoachGoalStore.remove(_:)` needs this — a deleted
    /// goal leaves no way to reach its keys again, so without it they sit in `UserDefaults` forever.
    /// (Editing a goal needs no cleanup: that is what keying on the target date buys.)
    static func clear(goalId: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: deadlineKey(goalId: goalId, important: true))
        defaults.removeObject(forKey: deadlineKey(goalId: goalId, important: false))
        defaults.removeObject(forKey: reviewKey(goalId: goalId))
    }
}
