import Foundation

/// Where a goal actually stands — as ONE reading, shared by every surface that shows it.
///
/// This is the extracted form of what `JourneyView` used to compute privately. It moved out for a
/// simple reason: the Journey page is no longer the only place a goal's progress is drawn. The Today
/// card and the iOS goal widget show the same thing, and three private copies of "how full is the
/// ring" is exactly how two surfaces end up quietly disagreeing about the same goal.
///
/// The rule the Journey page exists to honour travels with it: **no invented percentages.**
/// `fraction` is non-nil ONLY when there is a real current measurement AND both ends of the range to
/// place it in. Everything else — a goal NOOP can hold but not measure, a goal with no baseline — gets
/// `nil` and an honest line, never a bar built on nothing. `runwayWeeks` is time, not progress, and is
/// deliberately kept separate so a caller can choose to draw the runway without ever mistaking it for
/// achievement.
///
/// Pure and side-effect-free: every input is a plain value the caller already has, so this is testable
/// with no app, no store, no strap.
enum GoalProgress {

    /// One goal's progress, ready to render.
    struct Reading: Equatable {
        /// Measured progress 0…1, or nil when nothing real backs it.
        var fraction: Double?
        /// The honest sentence under the ring ("62.0 kg now, from 68.0 toward 60.0 kg."), or nil when
        /// there is no current measurement at all for this kind.
        var line: String?
        /// Whole weeks until the target date. Negative once it passes; nil without a target date.
        var runwayWeeks: Double?
        /// The single measurement the fraction and the trend are both read from, or nil.
        var current: Double?

        /// True when `fraction` came from a real measurement — i.e. a ring may be filled.
        var isMeasured: Bool { fraction != nil }

        init(fraction: Double? = nil, line: String? = nil, runwayWeeks: Double? = nil,
             current: Double? = nil) {
            self.fraction = fraction
            self.line = line
            self.runwayWeeks = runwayWeeks
            self.current = current
        }
    }

    /// The one real measurement a goal of this kind is read from, or nil when NOOP cannot measure it.
    /// Kept separate from `reading` because the trend card needs the bare value without the framing.
    static func currentMeasurement(goal: CoachGoal,
                                   evidence: GoalFeasibility.Evidence,
                                   latestWeightKg: Double?) -> Double? {
        switch goal.kind {
        case .run:         return evidence.longestRecentRunKm
        case .sleep:       return evidence.meanSleepHours
        case .weight:      return latestWeightKg
        case .consistency: return evidence.sessionsPerWeek
        case .strength, .stress, .recovery, .custom: return nil
        }
    }

    /// The full reading for one goal.
    static func reading(goal: CoachGoal,
                        evidence: GoalFeasibility.Evidence,
                        latestWeightKg: Double?,
                        now: Date = Date()) -> Reading {
        let runway = goal.weeksRemaining(from: now)
        let current = currentMeasurement(goal: goal, evidence: evidence, latestWeightKg: latestWeightKg)
        guard let current else { return Reading(runwayWeeks: runway) }

        // Consistency is a "reach this rate" goal rather than a "travel from A to B" one: the baseline
        // is not part of the arithmetic, so it keeps its own shape instead of going through `ranged`.
        if goal.kind == .consistency {
            guard let target = goal.target, target > 0 else {
                return Reading(runwayWeeks: runway, current: current)
            }
            return Reading(fraction: min(1, max(0, current / target)),
                           line: String(format: "Averaging %.1f sessions/week toward a target of %.0f.",
                                        current, target),
                           runwayWeeks: runway,
                           current: current)
        }

        let unit = goal.kind.unit
        guard let baseline = goal.baseline, let target = goal.target, target != baseline else {
            return Reading(line: String(format: "Currently %.1f %@. Set a starting point and target to "
                                        + "see a progress bar.", current, unit),
                           runwayWeeks: runway,
                           current: current)
        }
        return Reading(fraction: min(1, max(0, (current - baseline) / (target - baseline))),
                       line: String(format: "%.1f %@ now, from %.1f toward %.1f %@.",
                                    current, unit, baseline, target, unit),
                       runwayWeeks: runway,
                       current: current)
    }
}
