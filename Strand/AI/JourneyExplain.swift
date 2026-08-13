import Foundation

/// What the Journey page's numbers actually mean — the single place that defines them.
///
/// The page could already show "No sessions completed" against a stress goal without anywhere saying
/// what a session IS for a stress goal, a progress bar without saying what fed it, and a Readiness card
/// that looks goal-specific but isn't. A number nobody can derive is worse than no number: it invites the
/// user to trust or distrust it for the wrong reasons.
///
/// So: one pure, side-effect-free type (no store, no SwiftUI, no strap — testable on its own) that owns
/// both the DEFINITION and its plain-English explanation, so the card and the sentence under it can never
/// drift apart.
enum JourneyExplain {

    // MARK: - What counts as a "session", per goal kind

    /// The unit of progress for a kind of goal, and what actually increments it.
    ///
    /// The noun matters as much as the rule: counting "sessions" for a sleep goal was never meaningful —
    /// nights are what that goal is made of — and calling a weigh-in a session is just wrong.
    struct SessionRule: Equatable {
        /// Singular/plural unit noun, e.g. "session" / "sessions", "night" / "nights".
        ///
        /// Stored as the English source word and resolved through the catalog at every USE
        /// (`localizedNoun`), never spliced in raw. Interpolating the raw literal into a
        /// `String(localized:)` frame produced sentences like "Kein weigh-ins wurde aufgezeichnet" —
        /// a translated frame with an English word wedged into it, in every language at once.
        let noun: String
        let pluralNoun: String

        var localizedNoun: String { noun.localizedCatalogValue }
        var localizedPluralNoun: String { pluralNoun.localizedCatalogValue }
        /// One sentence: what increments this counter.
        let definition: String
        /// Whether a plan session the user ticked off counts.
        let countsPlanSessions: Bool
        /// Whether the user can log something against this goal by hand (the counter isn't purely derived).
        let allowsManualLog: Bool

        /// "3 sessions" / "1 night" / "no sessions" — in the reader's language.
        func countLabel(_ n: Int) -> String {
            n == 1 ? String(localized: "1 \(localizedNoun)")
                   : String(localized: "\(n) \(localizedPluralNoun)")
        }
    }

    static func sessionRule(for kind: CoachGoal.Kind) -> SessionRule {
        switch kind {
        case .run, .consistency, .strength:
            return SessionRule(
                noun: "session", pluralNoun: "sessions",
                definition: String(localized: "A session counts when you tick it off in Your plan, or log it against this goal here. Workouts your strap records aren't counted automatically — the coach can't tell which of them you meant for this goal."),
                countsPlanSessions: true, allowsManualLog: true)
        case .sleep:
            return SessionRule(
                noun: "night", pluralNoun: "nights",
                definition: String(localized: "This goal is measured in nights slept, not sessions trained — your strap records them, so there's nothing for you to tick off."),
                countsPlanSessions: false, allowsManualLog: false)
        case .recovery:
            return SessionRule(
                noun: "session", pluralNoun: "sessions",
                definition: String(localized: "Recovery isn't something you do a session of — it's read from your Charge and HRV. Sessions here are only the ones you deliberately logged as helping (a rest day, a mobility session)."),
                countsPlanSessions: true, allowsManualLog: true)
        case .stress:
            return SessionRule(
                noun: "session", pluralNoun: "sessions",
                definition: String(localized: "A session here is something you did FOR the goal — a breathing exercise, a walk, a mobility session — either ticked off in Your plan or logged against this goal. Your stress and HRV data are shown separately; they're context, not a count."),
                countsPlanSessions: true, allowsManualLog: true)
        case .weight:
            return SessionRule(
                noun: "weigh-in", pluralNoun: "weigh-ins",
                definition: String(localized: "Body weight moves with what you eat, and NOOP has no nutrition data. What's counted here is weigh-ins — training sessions are shown under Planned vs actual instead."),
                countsPlanSessions: false, allowsManualLog: false)
        case .custom:
            // The honest fallback for a goal NOOP cannot categorise at all: anything the user attributed
            // to it, plus any session they completed since setting it. Better a stated, generic rule than
            // a counter permanently stuck at zero with no explanation.
            return SessionRule(
                noun: "session", pluralNoun: "sessions",
                definition: String(localized: "This is your own goal, so NOOP can't know what counts towards it. Anything you log against it counts, as does any session you tick off in Your plan while it's active."),
                countsPlanSessions: true, allowsManualLog: true)
        }
    }

    /// The count line for the Progress card — a real statement of what has happened, in the right noun.
    static func countLine(for kind: CoachGoal.Kind, count: Int) -> String {
        let rule = sessionRule(for: kind)
        if count == 0 {
            return String(localized: "No \(rule.localizedPluralNoun) recorded since you set this goal.")
        }
        return String(localized: "\(rule.countLabel(count)) since you set this goal.")
    }

    // MARK: - Where the progress bar comes from

    /// How the Progress card is derived for this kind — including, for the kinds that get no bar at all,
    /// why not. Mirrors `JourneyView.measuredProgress` exactly; if that changes, this changes with it.
    static func progressExplanation(for kind: CoachGoal.Kind) -> String {
        switch kind {
        case .run:
            return String(localized: "The bar is your longest recent run placed between your starting point and your target distance. It needs both of those set, and at least one run recorded.")
        case .sleep:
            return String(localized: "The bar is your recent average nightly sleep placed between your starting point and your target. It needs both set, and enough nights recorded.")
        case .weight:
            return String(localized: "The bar is your most recent logged weight placed between your starting point and your target. Without a synced weigh-in there is no bar — NOOP won't estimate your weight.")
        case .consistency:
            return String(localized: "The bar is your recent sessions-per-week against your weekly target. It needs a target above zero and enough training history to average.")
        case .strength, .stress, .recovery, .custom:
            return String(localized: "There's no progress bar for this kind of goal, and that's deliberate: your strap can't measure it, so any percentage here would be invented. What's shown instead is what did happen — what you completed, and your recovery context.")
        }
    }

    // MARK: - Readiness

    /// Why the Readiness card looks the same on every goal: because it IS the same — the app-wide
    /// readiness read, shown here as context. Saying so stops it from being mistaken for a goal metric.
    static let readinessExplanation = String(localized: "Readiness is today's whole-body read — the same value Today shows, from your Charge, HRV and recent load. It is not specific to this goal and doesn't move with your progress; it's here to say whether today is a day to push towards the goal or to leave it alone.")

    // MARK: - Trend towards the goal

    enum TrendVerdict: String, Equatable {
        /// Further along than the elapsed time would suggest.
        case ahead
        /// Roughly where the runway says you should be.
        case onTrack
        /// Behind the pace the target date demands.
        case behind
        /// Not enough of the goal is measurable to say anything honest.
        case notMeasurable
    }

    struct Trend: Equatable {
        let verdict: TrendVerdict
        /// One sentence stating the comparison in the numbers it used.
        let line: String
    }

    /// How much of the runway has to be gone before a trend means anything. Under this, "behind" is just
    /// noise from a goal set last week.
    static let minElapsedFractionForTrend = 0.1
    /// How far from the expected fraction counts as ahead/behind rather than on track.
    static let trendTolerance = 0.1

    /// Progress made against progress expected — the deterministic version of a judgement the coach used
    /// to make in prose.
    ///
    /// It compares two fractions: how far along the baseline→target range the CURRENT measurement sits,
    /// and how much of the createdAt→targetDate runway has elapsed. Nothing is predicted and nothing is
    /// extrapolated; if either fraction can't be computed from real data, the answer is `.notMeasurable`,
    /// which is a correct and common answer.
    static func trend(goal: CoachGoal, current: Double?, now: Date = Date()) -> Trend {
        guard goal.kind.isQuantified,
              let current,
              let baseline = goal.baseline,
              let target = goal.target,
              baseline != target else {
            return Trend(verdict: .notMeasurable,
                         line: String(localized: "There's no trend to show: this goal needs a starting point, a target and a measurement before progress can be compared to time."))
        }
        guard let targetDate = goal.targetDate else {
            return Trend(verdict: .notMeasurable,
                         line: String(localized: "Without a target date there's no pace to measure against — only where you are now."))
        }
        let total = targetDate.timeIntervalSince(goal.createdAt)
        let elapsed = now.timeIntervalSince(goal.createdAt)
        guard total > 0, elapsed > 0 else {
            return Trend(verdict: .notMeasurable,
                         line: String(localized: "The runway for this goal has no length yet, so there's nothing to compare against."))
        }
        let elapsedFraction = elapsed / total
        guard elapsedFraction >= minElapsedFractionForTrend else {
            return Trend(verdict: .notMeasurable,
                         line: String(localized: "It's too early to call a trend — barely any of the runway has passed."))
        }
        // Signed by the goal's own direction, so a weight goal counting DOWN reads the same way up.
        let achievedFraction = (current - baseline) / (target - baseline)
        let achievedPct = Int((achievedFraction * 100).rounded())
        let elapsedPct = Int((min(elapsedFraction, 1) * 100).rounded())
        let comparison = String(localized: "You're \(achievedPct)% of the way from your starting point to your target, with \(elapsedPct)% of the time gone.")

        if achievedFraction >= elapsedFraction + trendTolerance {
            return Trend(verdict: .ahead,
                         line: comparison + " " + String(localized: "That's ahead of the pace the target date asks for."))
        }
        if achievedFraction >= elapsedFraction - trendTolerance {
            return Trend(verdict: .onTrack,
                         line: comparison + " " + String(localized: "That's about the pace the target date asks for."))
        }
        return Trend(verdict: .behind,
                     line: comparison + " " + String(localized: "That's behind the pace the target date asks for — worth talking to the coach about the date or the target, rather than just training harder."))
    }

    /// How the trend is computed, for the card's own explanation.
    static let trendExplanation = String(localized: "The trend compares two things and nothing else: how far you've moved from your starting point towards your target, and how much of the time until your target date has passed. It never predicts — a goal without a starting point, a target, a date or a real measurement simply has no trend.")

    /// The word shown beside the trend. Never colour alone — this is the readable half of that pairing.
    static func label(for verdict: TrendVerdict) -> String {
        switch verdict {
        case .ahead:         return String(localized: "Ahead")
        case .onTrack:       return String(localized: "On track")
        case .behind:        return String(localized: "Behind")
        case .notMeasurable: return String(localized: "Not measurable")
        }
    }
}
