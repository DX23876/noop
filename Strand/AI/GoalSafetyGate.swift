import Foundation

/// Deterministic safety check on the RATE a goal demands. Pure, testable, and evaluated BEFORE and
/// INDEPENDENTLY of the language model.
///
/// WHY THIS IS CODE AND NOT A PROMPT: a language model asked "is losing 20 kg in two months safe?"
/// will usually say no — and "usually" is not a safety property. The hard line lives here, where it can
/// be tested against a table of cases; the model only ever narrates the verdict it is handed.
///
/// IT WARNS, IT DOES NOT BLOCK. Legitimate exceptions exist and matter: a bodybuilder in a deliberate
/// cut phase, someone starting from a very high body weight, anyone under medical supervision. Refusing
/// those outright would be both paternalistic and wrong. So a flagged rate asks for a reason, records
/// it (`CoachGoal.RiskAcknowledgement`), and then lets the user proceed with their eyes open.
///
/// WHY THE RATE IS RELATIVE, NOT ABSOLUTE: 1 kg/week is a very different proposition at 180 kg than at
/// 60 kg. Expressing the rate as a PERCENTAGE of the user's own body weight per week normalises that
/// automatically, so a heavier person is not flagged for a rate that is, proportionally, the same as a
/// lighter person's unflagged one. That single choice handles the obesity case without special-casing it.
///
/// SCOPE: this judges the rate a goal implies. It is not medical advice and NOOP is not a medical
/// device (see DISCLAIMER.md). Note also that NOOP holds no nutrition data whatsoever, so for a weight
/// goal the coach tracks the number and plans TRAINING around it — it never prescribes a diet, which is
/// where body-weight change is actually won or lost.
enum GoalSafetyGate {

    enum Verdict: String, Codable, Equatable {
        /// The implied rate is within a conservative band, or there is no rate to judge.
        case ok
        /// Beyond the conservative band. Worth saying out loud; the user may proceed.
        case aggressive
        /// Well beyond it. Warned prominently and a reason is asked for before proceeding.
        case veryAggressive
        /// No rate could be computed (no target, no date, no baseline, or an unquantified kind).
        case notApplicable
    }

    struct Assessment: Equatable {
        let verdict: Verdict
        /// The implied rate in the goal's own unit per week (signed: negative = a decrease).
        let ratePerWeek: Double?
        /// Human phrasing of the rate, e.g. "2.5 kg/week (3.1% of body weight)".
        let rateDescription: String?
        /// What to tell the user. nil when `.ok` / `.notApplicable`.
        let warning: String?
        /// True when the UI must collect a reason before letting the goal be saved.
        var requiresReason: Bool { verdict == .veryAggressive }
    }

    // MARK: - Thresholds (named so they are auditable and testable)

    /// Body-weight change per week, as a fraction of current body weight, above which we say something.
    /// ~0.75%/week ≈ 0.6 kg/week at 80 kg — around the upper edge of the commonly-cited conservative
    /// range for sustainable change.
    static let weightAggressiveFraction = 0.0075
    /// Above this we warn prominently and ask for a reason. ~1.5%/week ≈ 1.2 kg/week at 80 kg.
    static let weightVeryAggressiveFraction = 0.015

    /// Weekly increase in running volume, as a fraction of the starting volume, above which we say
    /// something. The "10% rule" is a widely used conservative convention in running (its evidence base
    /// is mixed, which is exactly why this warns rather than blocks).
    static let runVolumeAggressiveFraction = 0.10
    static let runVolumeVeryAggressiveFraction = 0.20

    // MARK: - Entry point

    /// Assess the rate `goal` implies. `bodyWeightKg` comes from the user's profile and is only used
    /// for weight goals (to normalise the rate); pass whatever the profile holds.
    static func assess(goal: CoachGoal, bodyWeightKg: Double, now: Date = Date()) -> Assessment {
        let none = Assessment(verdict: .notApplicable, ratePerWeek: nil,
                              rateDescription: nil, warning: nil)
        guard goal.kind.isQuantified,
              let baseline = goal.baseline,
              let target = goal.target,
              let weeks = goal.weeksRemaining(from: now), weeks > 0
        else { return none }

        let change = target - baseline
        let ratePerWeek = change / weeks
        guard abs(change) > 0 else { return none }

        switch goal.kind {
        case .weight:
            return assessWeight(ratePerWeek: ratePerWeek, bodyWeightKg: bodyWeightKg)
        case .run:
            return assessRunVolume(ratePerWeek: ratePerWeek, baseline: baseline)
        case .consistency, .sleep, .strength, .custom:
            // No established rate-of-change risk we can judge honestly from what NOOP measures. Saying
            // nothing is better than inventing a threshold.
            return Assessment(verdict: .ok, ratePerWeek: ratePerWeek, rateDescription: nil, warning: nil)
        }
    }

    // MARK: - Per-kind rules

    private static func assessWeight(ratePerWeek: Double, bodyWeightKg: Double) -> Assessment {
        // Without a usable body weight we cannot normalise, and an absolute kg/week threshold would be
        // exactly the unfair-to-heavy-people rule this design avoids. Report the rate, judge nothing.
        guard bodyWeightKg > 0 else {
            return Assessment(verdict: .notApplicable,
                              ratePerWeek: ratePerWeek,
                              rateDescription: String(format: "%.2f kg/week", abs(ratePerWeek)),
                              warning: "Add your body weight in your profile and I can sense-check this rate.")
        }
        let fraction = abs(ratePerWeek) / bodyWeightKg
        let desc = String(format: "%.2f kg/week (%.1f%% of body weight per week)",
                          abs(ratePerWeek), fraction * 100)
        let direction = ratePerWeek < 0 ? "lose" : "gain"

        if fraction > weightVeryAggressiveFraction {
            return Assessment(
                verdict: .veryAggressive,
                ratePerWeek: ratePerWeek,
                rateDescription: desc,
                warning: "That works out to \(desc) — well beyond the pace usually considered "
                    + "sustainable. There are real reasons to \(direction) faster than usual (a "
                    + "deliberate cut, a high starting weight, medical supervision), so this is your "
                    + "call — but tell me why and I'll note it. Either way: I plan your training, not "
                    + "your nutrition, which is where most of this is actually decided.")
        }
        if fraction > weightAggressiveFraction {
            return Assessment(
                verdict: .aggressive,
                ratePerWeek: ratePerWeek,
                rateDescription: desc,
                warning: "That's \(desc) — on the brisk side. Doable, but keep an eye on recovery, and "
                    + "remember I plan your training, not your nutrition.")
        }
        return Assessment(verdict: .ok, ratePerWeek: ratePerWeek, rateDescription: desc, warning: nil)
    }

    private static func assessRunVolume(ratePerWeek: Double, baseline: Double) -> Assessment {
        let desc = String(format: "%.1f km/week", abs(ratePerWeek))
        // Only a build-up carries progression risk; scaling back does not.
        guard ratePerWeek > 0 else {
            return Assessment(verdict: .ok, ratePerWeek: ratePerWeek, rateDescription: desc, warning: nil)
        }
        // From a standing start there is no volume to take a percentage of. The absolute jump is what
        // matters then, and feasibility (not safety) is the better lens — leave it to that check.
        guard baseline > 0 else {
            return Assessment(verdict: .ok, ratePerWeek: ratePerWeek, rateDescription: desc, warning: nil)
        }
        let fraction = ratePerWeek / baseline
        let pct = String(format: "%.0f%%", fraction * 100)
        if fraction > runVolumeVeryAggressiveFraction {
            return Assessment(
                verdict: .veryAggressive,
                ratePerWeek: ratePerWeek,
                rateDescription: desc,
                warning: "That needs about +\(pct) volume per week (\(desc)) — a steep ramp, and ramping "
                    + "is where running injuries usually come from. If you have a reason to push it "
                    + "anyway, tell me and I'll note it; otherwise a later date would buy a lot of safety.")
        }
        if fraction > runVolumeAggressiveFraction {
            return Assessment(
                verdict: .aggressive,
                ratePerWeek: ratePerWeek,
                rateDescription: desc,
                warning: "That's about +\(pct) volume per week (\(desc)) — a touch above the ~10%/week "
                    + "convention. Workable if you're feeling good; I'll watch your load ratio.")
        }
        return Assessment(verdict: .ok, ratePerWeek: ratePerWeek, rateDescription: desc, warning: nil)
    }
}
