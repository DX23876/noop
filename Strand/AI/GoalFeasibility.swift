import Foundation
import WhoopStore
import StrandAnalytics

/// Is the goal REALISTIC? A separate question from `GoalSafetyGate`'s "is the rate dangerous?", and
/// deliberately answered differently.
///
/// WHAT THIS DOES NOT DO: predict. There are published VO₂max→race-time models, and building one here
/// would be inventing science the project has decided not to invent (and NOOP's VO₂max estimate is
/// itself nil unless the user has entered a waist measurement, so a predictor would be unavailable for
/// most people anyway). Instead this reports the EVIDENCE — what the user's own history actually shows
/// about their starting point — and only flags the cases that are plainly out of reach.
///
/// `.unknown` is a first-class, common, CORRECT answer. Saying "I can't judge this from what I can
/// measure" is more useful than a confident guess, and it is the same honesty rule the rest of NOOP
/// follows: never show a made-up number.
enum GoalFeasibility {

    enum Verdict: String, Equatable {
        /// The evidence supports it at a routine rate of progress.
        case supported
        /// Reachable, but it needs everything to go right.
        case ambitious
        /// The evidence says no. Always paired with what IS reachable.
        case unrealistic
        /// No baseline or no measurement — we genuinely cannot say.
        case unknown
    }

    struct Assessment: Equatable {
        let verdict: Verdict
        /// Plain-English reasoning, citing the actual numbers it used.
        let rationale: String
        /// For `.unrealistic`: what would be reachable instead. nil otherwise.
        let suggestion: String?
    }

    /// What the app could actually measure about the user's starting point. Every field is optional
    /// because every field is genuinely often missing.
    struct Evidence: Equatable {
        /// Estimated VO₂max (ml/kg/min). nil without a waist measurement — reported as context only,
        /// never used as a predictor.
        var vo2max: Double?
        /// Longest single run in the recent window, km.
        var longestRecentRunKm: Double?
        /// Recent training sessions per week.
        var sessionsPerWeek: Double?
        /// Recent mean nightly sleep, hours.
        var meanSleepHours: Double?

        init(vo2max: Double? = nil, longestRecentRunKm: Double? = nil,
             sessionsPerWeek: Double? = nil, meanSleepHours: Double? = nil) {
            self.vo2max = vo2max
            self.longestRecentRunKm = longestRecentRunKm
            self.sessionsPerWeek = sessionsPerWeek
            self.meanSleepHours = meanSleepHours
        }
    }

    // MARK: - Thresholds

    /// A run target this many times the user's longest recent run, inside the runway, reads as out of
    /// reach. Deliberately generous — this is a "that's not happening" backstop, not a coaching opinion.
    static let runUnrealisticMultiple = 4.0
    /// Above this multiple it's reachable but everything has to go right.
    static let runAmbitiousMultiple = 2.0
    /// Weekly session count beyond which a jump reads as a lifestyle change rather than a training one.
    static let consistencyAmbitiousJump = 3.0

    // MARK: - Entry point

    static func assess(goal: CoachGoal, evidence: Evidence, now: Date = Date()) -> Assessment {
        guard let weeks = goal.weeksRemaining(from: now) else {
            return Assessment(verdict: .unknown,
                              rationale: "No target date set, so there's no runway to judge against.",
                              suggestion: nil)
        }
        guard weeks > 0 else {
            return Assessment(verdict: .unknown,
                              rationale: "That target date has already passed.",
                              suggestion: nil)
        }

        switch goal.kind {
        case .run:         return assessRun(goal: goal, evidence: evidence, weeks: weeks)
        case .consistency: return assessConsistency(goal: goal, evidence: evidence)
        case .sleep:       return assessSleep(goal: goal, evidence: evidence)
        case .weight:
            // Body weight is decided mostly by nutrition, which NOOP has no data on. Judging
            // feasibility would mean pretending otherwise. The RATE is still checked — by the safety
            // gate, which is the honest place for it.
            return Assessment(
                verdict: .unknown,
                rationale: "I track your weight but I have no nutrition data, and that's where most of "
                    + "weight change is decided — so I won't pretend to judge whether this lands. I've "
                    + "sense-checked the pace separately, and I'll plan your training around it.",
                suggestion: nil)
        case .strength, .custom:
            return Assessment(
                verdict: .unknown,
                rationale: "I can hold this goal and shape your training around it, but I can't measure "
                    + "it from your strap — so I won't guess at progress. Tell me how it's going and "
                    + "I'll factor that in.",
                suggestion: nil)
        }
    }

    // MARK: - Per-kind

    private static func assessRun(goal: CoachGoal, evidence: Evidence, weeks: Double) -> Assessment {
        guard let target = goal.target, target > 0 else {
            return Assessment(verdict: .unknown,
                              rationale: "No target distance set, so there's nothing to size up.",
                              suggestion: nil)
        }
        let vo2Note = evidence.vo2max.map {
            String(format: " (for context, your estimated VO₂max is %.0f ml/kg/min)", $0)
        } ?? ""

        guard let longest = evidence.longestRecentRunKm, longest > 0 else {
            return Assessment(
                verdict: .unknown,
                rationale: "I can't see any recent runs, so I don't know your starting point. That's not "
                    + "a no — plenty of people start from zero — I just can't size it up until you've "
                    + "logged a few runs." + vo2Note,
                suggestion: nil)
        }

        let multiple = target / longest
        let longestText = String(format: "%.1f km", longest)
        let targetText = String(format: "%.1f km", target)
        let weeksText = String(format: "%.0f", weeks.rounded())

        if multiple > runUnrealisticMultiple {
            let reachable = longest * runAmbitiousMultiple
            return Assessment(
                verdict: .unrealistic,
                rationale: "\(targetText) in \(weeksText) weeks is more than \(String(format: "%.0f", multiple))× "
                    + "your longest recent run (\(longestText)). That's not a build-up, that's a leap — and "
                    + "leaps are where injuries come from." + vo2Note,
                suggestion: String(format: "From \(longestText), something around %.0f km by then is a "
                                   + "solid, safe stretch — or keep \(targetText) and give it more runway.",
                                   reachable))
        }
        if multiple > runAmbitiousMultiple {
            return Assessment(
                verdict: .ambitious,
                rationale: "\(targetText) is about \(String(format: "%.1f", multiple))× your longest recent "
                    + "run (\(longestText)), with \(weeksText) weeks to get there. Reachable, but it needs a "
                    + "consistent build and no interruptions." + vo2Note,
                suggestion: nil)
        }
        return Assessment(
            verdict: .supported,
            rationale: "You've already run \(longestText), so \(targetText) in \(weeksText) weeks is a "
                + "routine progression rather than a stretch." + vo2Note,
            suggestion: nil)
    }

    private static func assessConsistency(goal: CoachGoal, evidence: Evidence) -> Assessment {
        guard let target = goal.target, target > 0 else {
            return Assessment(verdict: .unknown,
                              rationale: "No weekly session target set.", suggestion: nil)
        }
        guard let current = evidence.sessionsPerWeek else {
            return Assessment(verdict: .unknown,
                              rationale: "I can't see enough recent training history to know where you're "
                                  + "starting from.", suggestion: nil)
        }
        let jump = target - current
        let currentText = String(format: "%.1f", current)
        let targetText = String(format: "%.0f", target)
        if jump > consistencyAmbitiousJump {
            return Assessment(
                verdict: .ambitious,
                rationale: "You're averaging \(currentText) sessions a week and aiming for \(targetText). "
                    + "That's a real change in your week, not just your training — the usual thing that "
                    + "breaks is the calendar, not the body.",
                suggestion: nil)
        }
        return Assessment(
            verdict: .supported,
            rationale: "You're averaging \(currentText) sessions a week; \(targetText) is a step up you can "
                + "hold.",
            suggestion: nil)
    }

    private static func assessSleep(goal: CoachGoal, evidence: Evidence) -> Assessment {
        guard let target = goal.target, target > 0 else {
            return Assessment(verdict: .unknown, rationale: "No sleep target set.", suggestion: nil)
        }
        guard let current = evidence.meanSleepHours else {
            return Assessment(verdict: .unknown,
                              rationale: "Not enough nights recorded yet to know your usual.", suggestion: nil)
        }
        let delta = target - current
        let currentText = String(format: "%.1f h", current)
        let targetText = String(format: "%.1f h", target)
        if delta > 1.5 {
            return Assessment(
                verdict: .ambitious,
                rationale: "You're averaging \(currentText) and aiming for \(targetText) — that's a big shift, "
                    + "and it's a schedule problem more than a training one.",
                suggestion: nil)
        }
        return Assessment(
            verdict: .supported,
            rationale: "You're averaging \(currentText); \(targetText) is within reach of a earlier, steadier "
                + "bedtime.",
            suggestion: nil)
    }
}

// The app-specific assembly of `Evidence` from the repository lives with the engine's other
// repo-reading helpers in AICoach.swift (`goalEvidence()`), keeping this file pure decision logic that
// can be tested against hand-built evidence with no app, no store and no strap.
