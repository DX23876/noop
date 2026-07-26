import Foundation

/// Deterministic check on the COMBINED training load implied by all simultaneously active goals
/// (#R-multi-goal, list item 2's plausibility check). Pure, testable, evaluated independently of the
/// language model — same shape and same governing principle as `GoalSafetyGate`: **warn, require a
/// reason, then allow. Never block.**
///
/// SCOPE, deliberately narrow: the classic "these two goals contradict each other" case (e.g. two
/// opposing weight targets) can no longer occur once `CoachGoalStore` enforces one active goal per
/// `Kind` — you simply can't have two `.weight` goals pulling in different directions at the same time.
/// What CAN still happen under that rule is a *volume* problem: a run goal + a consistency goal + a
/// strength goal, each individually reasonable, adding up to more training than a week can hold. This
/// gate only judges that combined-volume case; it does not attempt kind-pair contradiction detection,
/// since the one scenario that would need it is already structurally prevented.
///
/// The per-kind weekly-session estimate below is DELIBERATELY COARSE — NOOP has no load-tracking for
/// strength and no fixed weekly-frequency field on a run goal, so these are named, auditable
/// approximations (mirroring `GoalSafetyGate`'s own named thresholds), not a measurement.
enum GoalVolumeGate {

    enum Verdict: Equatable {
        /// No combined-volume concern — either nothing to sum, or the total is unremarkable.
        case ok
        /// The combined implied weekly load is high enough to mention.
        case volumeConcern
    }

    struct Assessment: Equatable {
        let verdict: Verdict
        /// The combined implied sessions/week across every active `run`/`consistency`/`strength` goal
        /// (including the one being drafted), for display.
        let combinedSessionsPerWeek: Double
        /// What to tell the user. nil for `.ok`.
        let warning: String?
    }

    // MARK: - Thresholds & per-kind estimates (named so they are auditable and testable)

    /// Combined implied weekly sessions above which we say something. Comfortably above what most
    /// weekly schedules can sustain alongside work/life/recovery.
    static let volumeConcernSessionsPerWeek = 10.0

    /// A `.consistency` goal's target IS sessions/week (its own literal unit) — used directly.
    /// A `.run` goal carries a distance/time target, not a weekly frequency, so any active run goal is
    /// assumed to imply a flat, typical training frequency.
    static let assumedRunSessionsPerWeek = 3.0
    /// `.strength` has no load tracking at all (held, not measured) — a flat, typical assumption.
    static let assumedStrengthSessionsPerWeek = 2.0

    // MARK: - Entry point

    /// Assess `draft` against the OTHER currently active goals. `excludingId` (the id being edited or
    /// replaced) is taken explicitly rather than from `draft.id` — a freshly-built draft always carries a
    /// brand-new random id (`CoachGoal.init`'s default), so relying on it would silently fail to exclude
    /// the goal actually being edited, double-counting it against its own stale copy in `activeGoals`.
    static func assess(draft: CoachGoal, against activeGoals: [CoachGoal],
                       excludingId: UUID? = nil) -> Assessment {
        let others = activeGoals.filter { $0.id != excludingId }
        let total = (others + [draft]).reduce(0.0) { sum, goal in
            sum + impliedSessionsPerWeek(goal)
        }
        guard total > volumeConcernSessionsPerWeek else {
            return Assessment(verdict: .ok, combinedSessionsPerWeek: total, warning: nil)
        }
        let n = others.filter { impliedSessionsPerWeek($0) > 0 }.count
        let combined = String(format: "%.0f", total.rounded())
        let warning = n > 0
            ? "Across this and your \(n) other active goal\(n == 1 ? "" : "s"), that's roughly "
                + "\(combined) sessions/week combined — more than most weeks can comfortably hold "
                + "alongside recovery. Doable if you're managing it, but worth keeping an eye on."
            : "That's roughly \(combined) sessions/week — more than most weeks can comfortably hold "
                + "alongside recovery. Doable if you're managing it, but worth keeping an eye on."
        return Assessment(verdict: .volumeConcern, combinedSessionsPerWeek: total, warning: warning)
    }

    private static func impliedSessionsPerWeek(_ goal: CoachGoal) -> Double {
        guard goal.status == .active || goal.status == .paused else { return 0 }
        switch goal.kind {
        case .consistency: return goal.target ?? 0
        case .run:         return assumedRunSessionsPerWeek
        case .strength:    return assumedStrengthSessionsPerWeek
        case .sleep, .weight, .stress, .recovery, .custom: return 0
        }
    }
}
