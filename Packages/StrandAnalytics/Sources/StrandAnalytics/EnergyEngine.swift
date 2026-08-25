import Foundation

// EnergyEngine.swift — one day's energy expenditure, from whichever sources actually covered it.
//
// Pure, DB-free, clock-injected. It exists for one reason: the numbers NOOP already stores are not
// the same quantity as each other, and adding them is wrong.
//
//   • Apple writes `active_kcal` and `basal_kcal` SEPARATELY. Their sum is the day's total burn.
//   • The strap path writes ONE number, `DailyMetric.activeKcalEst`, and despite the name it is a
//     TOTAL for the time the strap was worn: `Calories.estimateDayCalories` walks the day's HR
//     samples and adds, per second, EITHER the resting BMR rate (below the activity gate) OR the
//     Keytel rate (above it). Basal is already inside it.
//
// So `activeKcalEst + basalKcal` double-counts the basal rate for every worn second, while
// `activeKcal + basalKcal` is correct. Two fields with "kcal" in the name, one of which silently
// contains what the other measures — that trap is the whole reason this file exists rather than a
// couple of additions at the call sites.
//
// The second rule: sources are CHOSEN per day, never summed across. Two devices on one wrist measure
// the same body; adding them invents a person who burned twice. This mirrors what
// `Repository.sourceCandidates` already does for every other metric, and `MetricArbitrationPolicy`
// supplies the trust order when both are present.
//
// The third rule: a day nobody measured has NO total. `nil`, never 0 — "I have no data" and "you
// burned nothing" are different statements, and only one of them is ever true.

/// Which measurement actually produced a day's total burn. Surfaced so the detail screen (and the
/// coach) can say where a number came from rather than presenting every day as equally known.
public enum EnergySource: String, Equatable, Sendable, Codable {
    /// Apple's own split: active + basal, both measured. The strongest case.
    case appleSplit
    /// The strap's worn-time total, topped up with the profile BMR for the unworn remainder.
    case strapWornTime
    /// A mix — one source's measurement plus a modelled remainder, or two sources arbitrated.
    case mixed
    /// No energy measurement at all; steps scaled by body weight over the profile BMR.
    case stepsEstimate
    /// Nothing but the profile. `totalBurned` is nil here; only `estimatedBMR24h` is meaningful.
    case profileOnly
}
/// How much of a day the available sources actually covered.
///
/// The strap path persists the number of distinct HR seconds used by the calorie estimate. Each
/// coverage figure is optional on purpose: a missing signal means *unknown*, not zero and not full.
/// Treating "no Apple data" as "0% covered" would label a perfectly good strap-only day as unreliable.
public struct EnergyCoverage: Equatable, Sendable {
    /// Fraction of the elapsed day for which the calorie engine had a real HR second. This is available
    /// for NOOP's strap estimate only. Apple Health publishes cumulative energy, not a supported wear-
    /// duration signal, so Apple-only days deliberately leave it nil.
    public let energy: Double?
    /// Fraction of the day's hours that carry any step count (`appleStepHour`). A phone in a drawer
    /// and a watch on the wrist look different here, which is what makes it worth having alongside
    /// energy coverage.
    public let movement: Double?
    /// Whether the strap produced its own whole-day estimate for this day.
    public let hasStrapEstimate: Bool

    /// The best single answer to "how much of this day do we actually know about?" — the strongest
    /// available signal, not an average. Averaging with a missing source would drag a well-covered
    /// day down for the sin of having only one source.
    public var overall: Double? {
        energy
    }

    public init(energy: Double?, movement: Double?, hasStrapEstimate: Bool) {
        self.energy = energy
        self.movement = movement
        self.hasStrapEstimate = hasStrapEstimate
    }
}

/// One day's energy picture.
///
/// `estimatedBMR24h` and `basalBurnedSoFar` are deliberately separate fields, and confusing them is the
/// mistake the names exist to prevent: the first is a whole-day figure derived from the profile, the
/// second is what a wearable has accumulated SO FAR today. At 14:00 they differ by roughly half.
public struct DailyEnergySummary: Equatable, Sendable {
    public let day: String
    /// Modelled basal rate for a full 24 h. Present whenever the profile has usable body data, even
    /// on a day with no wearable at all — it is the one number NOOP can always stand behind.
    public let estimatedBMR24h: Double?
    /// Basal energy a wearable has actually recorded for this day so far. Nil without one.
    public let basalBurnedSoFar: Double?
    /// Energy above resting that a wearable recorded. Nil without one.
    public let activeBurnedSoFar: Double?
    /// The day's total expenditure. Nil when nothing measured it — never 0 as a stand-in.
    public let totalBurnedSoFar: Double?
    /// Where the day is heading, for the CURRENT day only. Always nil for a past day: a forecast for
    /// yesterday is not a forecast.
    public let projectedTotalBurn: Double?
    public let source: EnergySource
    public let coverage: EnergyCoverage
    /// Reuses the app-wide ladder rather than inventing a fourth vocabulary for certainty.
    public let confidence: ScoreConfidence

    public init(day: String, estimatedBMR24h: Double?, basalBurnedSoFar: Double?, activeBurnedSoFar: Double?,
                totalBurnedSoFar: Double?, projectedTotalBurn: Double?, source: EnergySource,
                coverage: EnergyCoverage, confidence: ScoreConfidence) {
        self.day = day
        self.estimatedBMR24h = estimatedBMR24h
        self.basalBurnedSoFar = basalBurnedSoFar
        self.activeBurnedSoFar = activeBurnedSoFar
        self.totalBurnedSoFar = totalBurnedSoFar
        self.projectedTotalBurn = projectedTotalBurn
        self.source = source
        self.coverage = coverage
        self.confidence = confidence
    }
}

public enum EnergyEngine {

    /// Clock information supplied by the repository. Using real local-day seconds rather than a fixed
    /// 86,400 keeps basal accrual and projections correct across daylight-saving transitions.
    public struct DayContext: Equatable, Sendable {
        public let isToday: Bool
        public let dayDurationSeconds: Double
        public let elapsedSeconds: Double

        public init(isToday: Bool, dayDurationSeconds: Double, elapsedSeconds: Double) {
            let duration = dayDurationSeconds.isFinite && dayDurationSeconds > 0
                ? dayDurationSeconds : 86_400
            self.isToday = isToday
            self.dayDurationSeconds = duration
            self.elapsedSeconds = isToday
                ? min(duration, max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0))
                : duration
        }

        public var elapsedFraction: Double {
            min(1, max(0, elapsedSeconds / dayDurationSeconds))
        }

        public static let completePastDay = DayContext(
            isToday: false, dayDurationSeconds: 86_400, elapsedSeconds: 86_400)
    }

    /// What one day contributes, gathered by the caller from the stores it already reads.
    public struct DayInputs: Equatable, Sendable {
        public let day: String
        /// Apple's active energy for the day (`AppleDaily.activeKcal` / `active_kcal`).
        public let appleActiveKcal: Double?
        /// Apple's basal energy so far (`AppleDaily.basalKcal` / `basal_kcal`).
        public let appleBasalKcal: Double?
        /// The strap's whole-day HR estimate (`DailyMetric.activeKcalEst`). A TOTAL for worn time —
        /// see this file's header before doing anything arithmetic with it.
        public let strapTotalKcal: Double?
        /// Number of distinct HR seconds that contributed to `strapTotalKcal`.
        public let strapCoverageSeconds: Int?
        public let steps: Int?
        /// Hours of the day carrying any step count, out of 24. Nil when hourly steps aren't stored.
        public let hoursWithSteps: Int?

        public init(day: String, appleActiveKcal: Double? = nil, appleBasalKcal: Double? = nil,
                    strapTotalKcal: Double? = nil, strapCoverageSeconds: Int? = nil,
                    steps: Int? = nil, hoursWithSteps: Int? = nil) {
            self.day = day
            self.appleActiveKcal = appleActiveKcal
            self.appleBasalKcal = appleBasalKcal
            self.strapTotalKcal = strapTotalKcal
            self.strapCoverageSeconds = strapCoverageSeconds
            self.steps = steps
            self.hoursWithSteps = hoursWithSteps
        }
    }

    // MARK: - Constants (named so they are auditable and testable)

    /// kcal per step per kg of body weight — the fallback when no energy measurement exists at all.
    /// ~0.0005 puts a 10 000-step day at ~400 kcal for an 80 kg adult, which is the commonly cited
    /// ballpark. A deliberately crude model for a deliberately crude situation: it never runs when a
    /// wearable contributed anything.
    public static let kcalPerStepPerKg = 0.0005

    /// Coverage at or above which a day is treated as fully known (`.solid`). Not 1.0: nobody wears a
    /// watch in the shower, and demanding perfection would mark every real day as partial.
    public static let solidCoverage = 0.80
    /// Below this the day is mostly modelled and the UI must say so.
    public static let buildingCoverage = 0.40

    // MARK: - One day

    /// Derive a day's energy summary.
    ///
    /// Local-day timing is injected rather than read from a clock so the projection is testable and
    /// so a past day can never accidentally acquire one.
    public static func summarize(_ inputs: DayInputs,
                                 profile: UserProfile,
                                 context: DayContext = .completePastDay) -> DailyEnergySummary {
        let bmr24h = Calories.bmrKcalPerDay(profile: profile)
        let clean = sanitized(inputs)
        let coverage = self.coverage(clean, context: context)

        let result = burn(clean, bmr24h: bmr24h, context: context, profile: profile)
        let projected = projectedBurn(result: result, bmr24h: bmr24h, context: context)

        return DailyEnergySummary(
            day: inputs.day,
            estimatedBMR24h: bmr24h,
            basalBurnedSoFar: result.basal,
            activeBurnedSoFar: result.active,
            totalBurnedSoFar: result.total,
            projectedTotalBurn: projected,
            source: result.source,
            coverage: coverage,
            confidence: confidence(source: result.source, coverage: coverage)
        )
    }

    // MARK: - Total burn (the selection matrix)

    /// The day's total expenditure and which source produced it.
    ///
    /// Every branch either takes ONE source's measurement or tops a measurement up with the modelled
    /// remainder. No branch adds two sources' measurements together — that is the invariant the tests
    /// exist to hold, because it is the mistake that looks most like ordinary arithmetic.
    private struct BurnResult {
        let basal: Double?
        let active: Double?
        let total: Double?
        let source: EnergySource
    }

    private static func burn(_ inputs: DayInputs, bmr24h: Double?,
                             context: DayContext,
                             profile: UserProfile) -> BurnResult {
        let elapsed = context.elapsedFraction
        let basalElapsed = bmr24h.map { $0 * elapsed }

        // 1. WHOOP is the canonical source whenever it produced a value. Apple can calibrate that
        //    value in a separate, opt-in model, but two devices measuring the same body are never
        //    arbitrated by silently replacing the always-worn strap with the occasional watch.
        //    The strap's worn-time total is topped up only with modelled basal for NOT-worn time.
        //    Adding the FULL day's BMR here would double-count every worn second, which is exactly
        //    the trap in this file's header.
        if let strap = inputs.strapTotalKcal, strap > 0 {
            guard let bmr24h,
                  let covered = inputs.strapCoverageSeconds else {
                // A legacy total has no trustworthy denominator. Preserve the observation but do not
                // invent a basal top-up or active/basal split from its magnitude.
                return BurnResult(basal: nil, active: nil, total: strap, source: .strapWornTime)
            }
            let observedSeconds = min(context.elapsedSeconds, max(0, Double(covered)))
            let basalRate = bmr24h / context.dayDurationSeconds
            let observedBasal = basalRate * observedSeconds
            let active = max(0, strap - observedBasal)
            let missingBasal = basalRate * max(0, context.elapsedSeconds - observedSeconds)
            return BurnResult(basal: basalElapsed, active: active,
                              total: strap + missingBasal, source: .strapWornTime)
        }

        // 2. Apple-only day. Both halves measured, nothing modelled. This path remains available for
        //    users/days without a WHOOP estimate, but never overrides an existing strap result.
        if let active = inputs.appleActiveKcal, let basal = inputs.appleBasalKcal, basal > 0 {
            return BurnResult(basal: basal, active: active, total: active + basal, source: .appleSplit)
        }

        // 3. Apple gave active energy but no basal figure — model the basal half.
        if let active = inputs.appleActiveKcal, let bmr24h {
            let basal = bmr24h * elapsed
            return BurnResult(basal: basal, active: active, total: active + basal, source: .mixed)
        }

        // 4. No energy measurement anywhere: scale steps by body weight over the modelled basal rate.
        if let steps = inputs.steps, steps > 0, let bmr24h, profile.weightKg > 0 {
            let active = Double(steps) * kcalPerStepPerKg * profile.weightKg
            let basal = bmr24h * elapsed
            return BurnResult(basal: basal, active: active, total: basal + active, source: .stepsEstimate)
        }

        // 5. Nothing. The BMR is still reported on the summary, but it is not a measured total and
        //    must not be presented as one.
        return BurnResult(basal: nil, active: nil, total: nil, source: .profileOnly)
    }

    /// Where the current day is heading: what has been spent so far, plus the same average rate over
    /// the hours that remain, floored at the basal rate for those hours — a person at rest still
    /// burns. Nil when nothing has been measured or the day has barely started (before ~10% elapsed
    /// the rate is too noisy to extrapolate from, and a wild morning figure reads as a malfunction).
    private static func projectedBurn(result: BurnResult, bmr24h: Double?,
                                      context: DayContext) -> Double? {
        guard context.isToday, let total = result.total, total > 0 else { return nil }
        let fraction = context.elapsedFraction
        guard fraction >= 0.10 else { return nil }
        guard fraction < 1.0 else { return total }
        guard let bmr24h, let active = result.active else { return nil }
        if result.source == .appleSplit, let basal = result.basal {
            return basal + bmr24h * (1 - fraction) + active / fraction
        }
        return bmr24h + active / fraction
    }

    // MARK: - Coverage

    private static func coverage(_ inputs: DayInputs, context: DayContext) -> EnergyCoverage {
        var energy: Double?
        if inputs.strapTotalKcal != nil, let seconds = inputs.strapCoverageSeconds,
           context.elapsedSeconds > 0 {
            energy = min(1, max(0, Double(seconds) / context.elapsedSeconds))
        }
        var movement: Double?
        if let hours = inputs.hoursWithSteps {
            movement = min(1.0, max(0.0, Double(hours) / 24.0))
        }
        return EnergyCoverage(energy: energy, movement: movement,
                              hasStrapEstimate: (inputs.strapTotalKcal ?? 0) > 0)
    }

    /// Reject malformed importer/model values before they can poison totals, chart ranges or widget JSON.
    private static func sanitized(_ inputs: DayInputs) -> DayInputs {
        func kcal(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0, value <= 20_000 else { return nil }
            return value
        }
        let steps = inputs.steps.flatMap { (0...200_000).contains($0) ? $0 : nil }
        let covered = inputs.strapCoverageSeconds.flatMap { (0...100_000).contains($0) ? $0 : nil }
        let hours = inputs.hoursWithSteps.flatMap { (0...25).contains($0) ? $0 : nil }
        return DayInputs(day: inputs.day,
                         appleActiveKcal: kcal(inputs.appleActiveKcal),
                         appleBasalKcal: kcal(inputs.appleBasalKcal),
                         strapTotalKcal: kcal(inputs.strapTotalKcal),
                         strapCoverageSeconds: covered,
                         steps: steps,
                         hoursWithSteps: hours)
    }

    /// How much to trust the day's total.
    ///
    /// A modelled day is never `.solid` however complete it looks, because completeness of a MODEL is
    /// not evidence. A measured day with no coverage signal at all sits at `.building` rather than
    /// `.calibrating`: the measurement exists, we just cannot say how much of the day it saw.
    private static func confidence(source: EnergySource, coverage: EnergyCoverage) -> ScoreConfidence {
        switch source {
        case .profileOnly, .stepsEstimate:
            return .calibrating
        case .appleSplit:
            return .solid
        case .strapWornTime, .mixed:
            guard let overall = coverage.overall else {
                return coverage.hasStrapEstimate ? .building : .calibrating
            }
            if overall >= solidCoverage { return .solid }
            return overall >= buildingCoverage ? .building : .calibrating
        }
    }
}
