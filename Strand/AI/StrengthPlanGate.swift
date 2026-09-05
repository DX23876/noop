import Foundation
import WhoopStore
import StrandAnalytics

/// Deterministic sanity check on a drafted training routine. Pure, testable, and evaluated BEFORE and
/// INDEPENDENTLY of the language model.
///
/// **WHY THIS IS CODE AND NOT A PROMPT** — the same reason `GoalSafetyGate` gives: a model asked "is
/// this jump in volume sensible?" will usually say something reasonable, and "usually" is not a safety
/// property. The line lives here where it can be tested against a table of cases; the model only ever
/// narrates the verdict it is handed.
///
/// **IT WARNS, IT DOES NOT BLOCK.** Exactly as `GoalSafetyGate` and `GoalVolumeGate` do. A big jump can
/// be entirely deliberate — the first week back after a deload, a planned overreaching block, someone
/// returning from a layoff who is nowhere near their old ceiling. Refusing those would be both
/// paternalistic and wrong. A flagged draft is shown with the warning attached, and the user decides.
///
/// **EVERY THRESHOLD IS RELATIVE TO THE USER'S OWN HISTORY**, never to a textbook. "Ten sets of chest"
/// means something different for someone averaging four than for someone averaging eighteen, and NOOP
/// has no evidence about what anyone's correct number is. What it does have is what they have actually
/// been doing, which is enough to notice a step change and say so.
enum StrengthPlanGate {

    // MARK: - Thresholds (documented, not magic)

    /// A prescribed per-muscle set count above this multiple of the user's own recent weekly average is
    /// worth mentioning. 1.5× is chosen to sit clearly above ordinary progression — the usual advice is
    /// to add a set or two per muscle per week, which from a base of eight is ~1.2× — while still
    /// catching a doubling.
    static let setJumpFactor = 1.5
    /// Below this many sets, the multiple is meaningless: going from one set to three is 3×, and also
    /// completely unremarkable. An absolute floor stops the ratio from firing on noise.
    static let setJumpFloor = 6
    /// A prescribed load above this fraction of the user's best estimated 1RM for that movement is worth
    /// mentioning. 1.0 is the honest line: prescribing MORE than the best single they are estimated to
    /// have in them is the claim that needs a second look.
    static let loadCeilingFraction = 1.0
    /// Weeks of history needed before either check runs. With less, the "user's own average" is one or
    /// two sessions and a warning drawn from it would be noise presented as a finding.
    static let minimumHistoryWeeks = 2

    // MARK: - Inputs

    /// What the gate compares against: the user's own recent training, already derived.
    struct History {
        /// Working sets per primary muscle group over the window, and how many weeks that window spans.
        let setsByMuscle: [HevyMuscleGroup: Int]
        let weeks: Double
        /// Best estimated 1RM seen per exercise template, over the same window.
        let bestE1RMByTemplate: [String: Double]

        /// Average working sets per week for one muscle group.
        func weeklySets(_ group: HevyMuscleGroup) -> Double? {
            guard weeks > 0, let total = setsByMuscle[group] else { return nil }
            return Double(total) / weeks
        }
    }

    /// Build the comparison history from stored sessions. Kept separate from the check so the check
    /// stays a pure function of numbers and can be tested without a database.
    static func history(from workouts: [HevyWorkout],
                        templates: [String: HevyExerciseTemplate],
                        windowDays: Int = 28,
                        now: Date = Date()) -> History {
        let cutoff = Int(now.timeIntervalSince1970) - windowDays * 86_400
        let recent = workouts.filter { $0.startTs >= cutoff }
        let tally = StrengthSession.hardSetsByMuscle(recent, templates: templates)

        var best: [String: Double] = [:]
        for workout in recent {
            for exercise in workout.exercises {
                guard let id = exercise.templateId else { continue }
                for set in exercise.workingSets {
                    if let e = OneRepMax.forSet(set, template: templates[id]) {
                        best[id] = max(best[id] ?? 0, e)
                    }
                }
            }
        }
        return History(setsByMuscle: tally.primary,
                       weeks: Double(windowDays) / 7.0,
                       bestE1RMByTemplate: best)
    }

    // MARK: - The check

    /// Warnings for a drafted routine, in a stable order. Empty means nothing stood out — which is not
    /// a claim that the routine is good, only that it does not step outside what this person already does.
    ///
    /// `weeklyFrequency` is how often the user says they will run this routine; a routine performed
    /// twice a week prescribes twice its per-session sets. It defaults to 1 because that is the only
    /// honest assumption when nobody has said — and under-counting is the direction that produces FEWER
    /// warnings, so the default cannot manufacture one.
    static func warnings(for proposal: HevyRoutineProposal,
                         templates: [String: HevyExerciseTemplate],
                         history: History,
                         weeklyFrequency: Double = 1) -> [String] {
        guard history.weeks >= Double(minimumHistoryWeeks) else {
            // Deliberately silent rather than cautious-by-default. With two weeks of data, any
            // "unusual" verdict is a statement about the data's thinness dressed up as one about the
            // plan, and a warning that fires on everyone teaches people to ignore warnings.
            return []
        }

        var out: [String] = []
        out.append(contentsOf: volumeWarnings(proposal, templates: templates, history: history,
                                              weeklyFrequency: weeklyFrequency))
        out.append(contentsOf: loadWarnings(proposal, templates: templates, history: history))
        return out
    }

    /// Per-muscle set counts that step well above the user's own weekly average.
    private static func volumeWarnings(_ proposal: HevyRoutineProposal,
                                       templates: [String: HevyExerciseTemplate],
                                       history: History,
                                       weeklyFrequency: Double) -> [String] {
        var prescribed: [HevyMuscleGroup: Int] = [:]
        for exercise in proposal.exercises {
            guard let template = templates[exercise.templateId] else { continue }
            let working = exercise.sets.filter { $0.type.countsAsWork }.count
            prescribed[template.primaryMuscleGroup, default: 0] += working
        }

        var out: [String] = []
        for (group, perSession) in prescribed.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let weekly = Double(perSession) * max(weeklyFrequency, 1)
            guard weekly >= Double(setJumpFloor), let usual = history.weeklySets(group), usual > 0,
                  weekly > usual * setJumpFactor else { continue }
            out.append(String(localized:
                "\(group.label): \(Int(weekly.rounded())) working sets a week, against your recent average of \(String(format: "%.0f", usual)). That is a big step up — deliberate is fine, accidental is worth a second look."))
        }
        return out
    }

    /// Loads prescribed above the best single the user is ESTIMATED to have in them.
    ///
    /// Estimated, and the wording says so: the comparison is against an Epley projection from their own
    /// working sets, not a max they actually attempted. A routine can legitimately exceed it — the
    /// estimate is conservative for a well-trained lifter — so this is worth mentioning, not blocking.
    private static func loadWarnings(_ proposal: HevyRoutineProposal,
                                     templates: [String: HevyExerciseTemplate],
                                     history: History) -> [String] {
        var out: [String] = []
        for exercise in proposal.exercises {
            guard let best = history.bestE1RMByTemplate[exercise.templateId], best > 0 else { continue }
            let heaviest = exercise.sets
                .filter { $0.type.countsAsWork }
                .compactMap(\.weightKg)
                .max()
            guard let heaviest, heaviest > best * loadCeilingFraction else { continue }
            out.append(String(localized:
                "\(exercise.title): \(String(format: "%.1f", heaviest)) kg is above your estimated one-rep max of \(String(format: "%.1f", best)) kg for this movement. The estimate is a projection, not a lift you made — but check the number."))
        }
        return out
    }
}
