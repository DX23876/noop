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

public enum EnergyCalibrationStatus: String, Equatable, Sendable, Codable {
    case off
    case learning
    case active
    case paused
}

public enum EnergyForecastStatus: String, Equatable, Sendable, Codable {
    case unavailable
    case learning
    case available
}
/// How much of a day the available sources actually covered.
///
/// The current strap path persists the wall-clock seconds whose basal share is already represented by
/// the bucket estimate. Legacy rows used distinct HR seconds. Each coverage figure is optional on
/// purpose: a missing signal means *unknown*, not zero and not full.
/// Treating "no Apple data" as "0% covered" would label a perfectly good strap-only day as unreliable.
public struct EnergyCoverage: Equatable, Sendable {
    /// Fraction of the elapsed day the day's ACTUAL source actually represented: context-modelled
    /// bucket seconds for WHOOP v4, or `healthEnergyBucket.coverageSeconds` for Apple (iOS only, where that reference
    /// stream exists — an `appleSplit` day on macOS, or any platform before the stream existed, leaves
    /// this nil rather than being marked down for a platform gap it didn't create).
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
    /// The forecast's honest width. Present whenever `projectedTotalBurn` is — a point estimate with
    /// no interval overstates what the model knows, and the interval is the more useful half.
    public let projectedRangeKcal: ClosedRange<Double>?
    public let forecastStatus: EnergyForecastStatus
    /// The WHOOP model output before an optional Apple Watch reference multiplier and basal top-up.
    public let rawWhoopTotalKcal: Double?
    /// Approximate symmetric model uncertainty. Nil for sources that do not publish one.
    public let uncertaintyFraction: Double?
    public let modelWeightKg: Double?
    public let modelWeightSource: String?
    /// Time whose elevated HR could not be attributed to movement or a trusted workout.
    public let unresolvedElevatedHRSeconds: Int
    /// The bounded Apple Watch reference multiplier applied to the WHOOP total. Nil means the
    /// calibration was disabled, unavailable or invalid. Apple remains a reference, not the source.
    public let appliedCalibrationFactor: Double?
    public let calibrationStatus: EnergyCalibrationStatus
    public let source: EnergySource
    public let coverage: EnergyCoverage
    /// Reuses the app-wide ladder rather than inventing a fourth vocabulary for certainty.
    public let confidence: ScoreConfidence

    public init(day: String, estimatedBMR24h: Double?, basalBurnedSoFar: Double?, activeBurnedSoFar: Double?,
                totalBurnedSoFar: Double?, projectedTotalBurn: Double?,
                projectedRangeKcal: ClosedRange<Double>? = nil, rawWhoopTotalKcal: Double? = nil,
                uncertaintyFraction: Double? = nil,
                unresolvedElevatedHRSeconds: Int = 0,
                modelWeightKg: Double? = nil, modelWeightSource: String? = nil,
                appliedCalibrationFactor: Double? = nil, source: EnergySource,
                coverage: EnergyCoverage, confidence: ScoreConfidence,
                calibrationStatus: EnergyCalibrationStatus = .off,
                forecastStatus: EnergyForecastStatus = .unavailable) {
        self.day = day
        self.estimatedBMR24h = estimatedBMR24h
        self.basalBurnedSoFar = basalBurnedSoFar
        self.activeBurnedSoFar = activeBurnedSoFar
        self.totalBurnedSoFar = totalBurnedSoFar
        self.projectedTotalBurn = projectedTotalBurn
        self.projectedRangeKcal = projectedRangeKcal
        self.forecastStatus = forecastStatus
        self.rawWhoopTotalKcal = rawWhoopTotalKcal
        self.uncertaintyFraction = uncertaintyFraction
        self.modelWeightKg = modelWeightKg
        self.modelWeightSource = modelWeightSource
        self.unresolvedElevatedHRSeconds = unresolvedElevatedHRSeconds
        self.appliedCalibrationFactor = appliedCalibrationFactor
        self.calibrationStatus = calibrationStatus
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
        /// Distinct seconds an Apple Health source (iPhone or Watch) actually reported for, from
        /// `healthEnergyBucket.coverageSeconds` where that reference stream exists (iOS only — see
        /// this property's use in `confidence(...)`). Nil means unknown, not full: an `appleSplit` day
        /// with no coverage signal at all keeps today's behaviour rather than being marked down for a
        /// platform gap. `.max` over sources per bucket, never summed — iPhone and Watch can cover the
        /// same window, and summing would push coverage past 100%.
        public let appleCoverageSeconds: Int?
        /// The strap's whole-day HR estimate (`DailyMetric.activeKcalEst`). A TOTAL for worn time —
        /// see this file's header before doing anything arithmetic with it.
        public let strapTotalKcal: Double?
        /// Wall-clock seconds whose basal share is already included in `strapTotalKcal`. Legacy rows
        /// may contain distinct HR seconds instead; model-version filtering prevents crossing them.
        public let strapCoverageSeconds: Int?
        /// Optional, user-enabled Apple Watch reference calibration. Values outside the deliberately
        /// narrow 0.8...1.2 range are ignored, and the factor is never applied to Apple-only days.
        public let strapCalibrationFactor: Double?
        public let strapUncertaintyFraction: Double?
        public let calibrationStatus: EnergyCalibrationStatus
        public let steps: Int?
        /// Hours of the day carrying any step count, out of 24. Nil when hourly steps aren't stored.
        public let hoursWithSteps: Int?
        public let unresolvedElevatedHRSeconds: Int
        public let modelWeightSource: String?

        public init(day: String, appleActiveKcal: Double? = nil, appleBasalKcal: Double? = nil,
                    appleCoverageSeconds: Int? = nil,
                    strapTotalKcal: Double? = nil, strapCoverageSeconds: Int? = nil,
                    strapCalibrationFactor: Double? = nil,
                    strapUncertaintyFraction: Double? = nil,
                    calibrationStatus: EnergyCalibrationStatus = .off,
                    steps: Int? = nil, hoursWithSteps: Int? = nil,
                    unresolvedElevatedHRSeconds: Int = 0,
                    modelWeightSource: String? = nil) {
            self.day = day
            self.appleActiveKcal = appleActiveKcal
            self.appleBasalKcal = appleBasalKcal
            self.appleCoverageSeconds = appleCoverageSeconds
            self.strapTotalKcal = strapTotalKcal
            self.strapCoverageSeconds = strapCoverageSeconds
            self.strapCalibrationFactor = strapCalibrationFactor
            self.strapUncertaintyFraction = strapUncertaintyFraction
            self.calibrationStatus = calibrationStatus
            self.steps = steps
            self.hoursWithSteps = hoursWithSteps
            self.unresolvedElevatedHRSeconds = unresolvedElevatedHRSeconds
            self.modelWeightSource = modelWeightSource
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
    /// - Parameters:
    ///   - shape: the user's personal time-of-day activity profile. Nil keeps the linear projection.
    ///   - adaptivePriorKcal: the long-horizon retrospective TDEE (`AdaptiveExpenditureEngine`). It
    ///     shrinks the FORECAST on a thinly-covered day and never touches `totalBurnedSoFar` — an
    ///     energy-balance model must not rewrite a measurement (see `fork/decisions.md`, 2026-08-25).
    public static func summarize(_ inputs: DayInputs,
                                 profile: UserProfile,
                                 context: DayContext = .completePastDay,
                                 shape: ActivityShape? = nil,
                                 adaptivePriorKcal: Double? = nil) -> DailyEnergySummary {
        let bmr24h = Calories.bmrKcalPerDay(profile: profile)
        let clean = sanitized(inputs)
        let coverage = self.coverage(clean, context: context)

        let result = burn(clean, bmr24h: bmr24h, context: context, profile: profile)
        // The adaptive food/weight estimate remains a separate retrospective comparison. It must not
        // silently rewrite today's wearable forecast.
        _ = adaptivePriorKcal
        let projected = projectedBurn(result: result, bmr24h: bmr24h,
                                      context: context, shape: shape)
        let uncertainty = clean.strapTotalKcal == nil ? nil : clean.strapUncertaintyFraction

        return DailyEnergySummary(
            day: inputs.day,
            estimatedBMR24h: bmr24h,
            basalBurnedSoFar: result.basal,
            activeBurnedSoFar: result.active,
            totalBurnedSoFar: result.total,
            projectedTotalBurn: projected,
            projectedRangeKcal: projectedRange(projected: projected, uncertainty: uncertainty,
                                               coverage: coverage, context: context),
            rawWhoopTotalKcal: result.rawWhoopTotalKcal,
            uncertaintyFraction: uncertainty,
            unresolvedElevatedHRSeconds: clean.unresolvedElevatedHRSeconds,
            modelWeightKg: profile.weightKg > 0 ? profile.weightKg : nil,
            modelWeightSource: clean.modelWeightSource,
            appliedCalibrationFactor: result.appliedCalibrationFactor,
            source: result.source,
            coverage: coverage,
            confidence: confidence(source: result.source, coverage: coverage),
            calibrationStatus: clean.calibrationStatus,
            forecastStatus: context.isToday ? (shape == nil ? .learning : .available) : .unavailable
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
        let appliedCalibrationFactor: Double?
        let rawWhoopTotalKcal: Double?

        init(basal: Double?, active: Double?, total: Double?, source: EnergySource,
             appliedCalibrationFactor: Double? = nil, rawWhoopTotalKcal: Double? = nil) {
            self.basal = basal
            self.active = active
            self.total = total
            self.source = source
            self.appliedCalibrationFactor = appliedCalibrationFactor
            self.rawWhoopTotalKcal = rawWhoopTotalKcal
        }
    }

    private static func burn(_ inputs: DayInputs, bmr24h: Double?,
                             context: DayContext,
                             profile: UserProfile) -> BurnResult {
        let elapsed = context.elapsedFraction

        // 1. WHOOP is the canonical source whenever it produced a value. Apple can calibrate that
        //    value in a separate, opt-in model, but two devices measuring the same body are never
        //    arbitrated by silently replacing the always-worn strap with the occasional watch.
        //    The strap's worn-time total is topped up only with modelled basal for NOT-worn time.
        //    Adding the FULL day's BMR here would double-count every worn second, which is exactly
        //    the trap in this file's header.
        if let strap = inputs.strapTotalKcal, strap > 0 {
            let factor = inputs.strapCalibrationFactor
            guard let bmr24h,
                  let covered = inputs.strapCoverageSeconds else {
                // A legacy total has no trustworthy denominator, so basal cannot be isolated from it.
                // Applying an ACTIVE-only factor to an unsplit total would be exactly the bug this
                // branch exists to avoid — better to preserve the observation uncalibrated than to
                // silently scale a number that includes basal by a factor fitted on activity alone.
                return BurnResult(basal: nil, active: nil, total: strap,
                                  source: .strapWornTime, appliedCalibrationFactor: nil,
                                  rawWhoopTotalKcal: strap)
            }
            let observedSeconds = min(context.elapsedSeconds, max(0, Double(covered)))
            let basalRate = bmr24h / context.dayDurationSeconds
            let observedBasal = basalRate * observedSeconds
            // Calibrate ACTIVE energy only. The Watch reference factor is fitted on activity-only
            // buckets (see `EnergyCalibrationEngine` / the fit in `Repository.refreshWhoopEnergyModel`),
            // so applying it to `strap` — which still contains WHOOP's own basal estimate for the
            // observed window — would scale a metabolic constant by a factor that was never fitted
            // against it. `rawActive` isolates the part the fit actually describes.
            let rawActive = max(0, strap - observedBasal)
            let active = rawActive * (factor ?? 1)
            let basalElapsedValue = bmr24h * elapsed
            return BurnResult(basal: basalElapsedValue, active: active,
                              total: basalElapsedValue + active, source: .strapWornTime,
                              appliedCalibrationFactor: factor, rawWhoopTotalKcal: strap)
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

    /// Where the current day is heading:
    ///
    ///     projected = spent so far + basal for the hours left + the activity still expected
    ///
    /// The last term is the whole point. It used to extrapolate today's active kcal linearly or divide
    /// by a tiny personal-shape fraction. A morning workout could therefore be multiplied across the
    /// whole day. The current model adds the historical median activity still expected in the remaining
    /// hours, with only a bounded 0.5...1.5 same-day adjustment once enough of the routine has elapsed.
    /// Without at least seven complete personal days there is no forecast.
    ///
    /// Nil when nothing has been measured or the day has barely started (before ~10% elapsed the rate
    /// is too noisy to extrapolate from, and a wild morning figure reads as a malfunction).
    private static func projectedBurn(result: BurnResult, bmr24h: Double?,
                                      context: DayContext, shape: ActivityShape?) -> Double? {
        guard context.isToday, let total = result.total, total > 0 else { return nil }
        let elapsed = context.elapsedFraction
        guard elapsed >= 0.10 else { return nil }
        guard elapsed < 1.0 else { return total }
        guard let bmr24h, let active = result.active else { return nil }

        guard let shape,
              let expected = shape.expectedActivity(elapsedSeconds: context.elapsedSeconds,
                                                    dayDurationSeconds: context.dayDurationSeconds)
        else { return nil }
        let expectedDaily = expected.toNow + expected.remaining
        var adjustment = 1.0
        if elapsed >= 0.25, expectedDaily > 0, expected.toNow >= expectedDaily * 0.20 {
            adjustment = min(1.5, max(0.5, active / max(1, expected.toNow)))
        }
        return total + bmr24h * (1 - elapsed) + expected.remaining * adjustment
    }

    /// The forecast as an interval rather than a point.
    ///
    /// A bare `~2,650 kcal` claims a precision the model does not have; `2,400–2,900` says the same
    /// thing honestly and tells the user something extra — a well-covered afternoon reads tight, a
    /// thin morning reads wide. Two independent sources of width:
    ///
    ///   • what the model already publishes about the energy it HAS measured (`uncertaintyFraction`,
    ///     itself weighted by the observed/inferred/modeled evidence mix), and
    ///   • how much of the day is still unlived — the unfinished part is a forecast, and no coverage
    ///     figure can speak for hours that have not happened.
    private static func projectedRange(projected: Double?, uncertainty: Double?,
                                       coverage: EnergyCoverage,
                                       context: DayContext) -> ClosedRange<Double>? {
        guard let projected, projected > 0 else { return nil }
        let measured = uncertainty ?? (coverage.overall.map { 0.10 + 0.20 * (1 - $0) } ?? 0.20)
        let unlived = 0.20 * (1 - context.elapsedFraction)
        let relative = min(0.50, max(0.04, measured + unlived))
        let half = projected * relative
        return max(0, projected - half)...(projected + half)
    }

    // MARK: - Coverage

    private static func coverage(_ inputs: DayInputs, context: DayContext) -> EnergyCoverage {
        var energy: Double?
        if inputs.strapTotalKcal != nil, let seconds = inputs.strapCoverageSeconds,
           context.elapsedSeconds > 0 {
            energy = min(1, max(0, Double(seconds) / context.elapsedSeconds))
        } else if inputs.strapTotalKcal == nil, let seconds = inputs.appleCoverageSeconds,
                  context.elapsedSeconds > 0 {
            // Only reached when Apple is actually the day's source: WHOOP wins whenever it produced a
            // value (rule 1, this file's header), so a strap total being nil is exactly the condition
            // under which `burn(...)` falls through to the Apple branches.
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
        /// A strap total of zero is what `burn(...)` already treats as "no strap data" (it guards
        /// `strap > 0`). Normalising it to nil HERE makes every other reader agree: without this,
        /// `coverage(...)` would hand an Apple-sourced day the strap's coverage denominator and
        /// `summarize` would attach the WHOOP model's uncertainty to an Apple total — three readers,
        /// two different answers to "is there strap data?".
        func strapKcal(_ value: Double?) -> Double? {
            guard let value = kcal(value), value > 0 else { return nil }
            return value
        }
        let steps = inputs.steps.flatMap { (0...200_000).contains($0) ? $0 : nil }
        let covered = inputs.strapCoverageSeconds.flatMap { (0...100_000).contains($0) ? $0 : nil }
        let appleCovered = inputs.appleCoverageSeconds.flatMap { (0...100_000).contains($0) ? $0 : nil }
        let hours = inputs.hoursWithSteps.flatMap { (0...25).contains($0) ? $0 : nil }
        let unresolved = min(100_000, max(0, inputs.unresolvedElevatedHRSeconds))
        let factor = inputs.strapCalibrationFactor.flatMap {
            $0.isFinite && EnergyCalibrationEngine.factorRange.contains($0) ? $0 : nil
        }
        let uncertainty = inputs.strapUncertaintyFraction.flatMap {
            $0.isFinite && (0...1).contains($0) ? $0 : nil
        }
        let calibrationStatus: EnergyCalibrationStatus =
            inputs.calibrationStatus == .active && factor == nil ? .learning : inputs.calibrationStatus
        return DayInputs(day: inputs.day,
                         appleActiveKcal: kcal(inputs.appleActiveKcal),
                         appleBasalKcal: kcal(inputs.appleBasalKcal),
                         appleCoverageSeconds: appleCovered,
                         strapTotalKcal: strapKcal(inputs.strapTotalKcal),
                         strapCoverageSeconds: covered,
                         strapCalibrationFactor: factor,
                         strapUncertaintyFraction: uncertainty,
                         calibrationStatus: calibrationStatus,
                         steps: steps,
                         hoursWithSteps: hours,
                         unresolvedElevatedHRSeconds: unresolved,
                         modelWeightSource: inputs.modelWeightSource)
    }

    /// How much to trust the day's total.
    ///
    /// A modelled day is never `.solid` however complete it looks, because completeness of a MODEL is
    /// not evidence. A measured day with no coverage signal at all sits at `.building` rather than
    /// `.calibrating`: the measurement exists, we just cannot say how much of the day it saw.
    ///
    /// `.appleSplit` runs the SAME ladder as the strap once a coverage signal exists — Apple reporting
    /// both active and basal energy is not proof the source covered the whole elapsed day, only that
    /// it covered whatever it saw. Where no coverage signal exists at all (macOS import, or any day
    /// before `healthEnergyBucket` existed), `.appleSplit` keeps today's `.solid` rather than being
    /// marked down for a platform gap it didn't create — an ABSENT signal is not evidence of a THIN one.
    private static func confidence(source: EnergySource, coverage: EnergyCoverage) -> ScoreConfidence {
        switch source {
        case .profileOnly, .stepsEstimate:
            return .calibrating
        case .appleSplit:
            guard let overall = coverage.overall else { return .solid }
            if overall >= solidCoverage { return .solid }
            return overall >= buildingCoverage ? .building : .calibrating
        case .strapWornTime, .mixed:
            guard let overall = coverage.overall else {
                return coverage.hasStrapEstimate ? .building : .calibrating
            }
            if overall >= solidCoverage { return .solid }
            return overall >= buildingCoverage ? .building : .calibrating
        }
    }
}
