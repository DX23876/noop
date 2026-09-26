import XCTest
@testable import StrandAnalytics

final class EnergyEngineTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
    private var bmr: Double { Calories.bmrKcalPerDay(profile: profile) ?? 0 }

    /// Local midnight of the day every session test places its windows against. The engine only ever
    /// works in offsets from it, so the exact instant is irrelevant — having ONE makes the windows in
    /// the tests below readable as clock times.
    private let dayStart = 1_756_000_000

    private func context(elapsed fraction: Double = 1, duration: Double = 86_400,
                         today: Bool = false, withStart: Bool = true) -> EnergyEngine.DayContext {
        .init(isToday: today, dayDurationSeconds: duration, elapsedSeconds: duration * fraction,
              startTs: withStart ? dayStart : nil)
    }

    /// A session window expressed in hours after local midnight.
    private func session(fromHour: Double, toHour: Double, kcal: Double,
                         source: ActivityContribution.Source = .apple,
                         estimated: Bool = false) -> ActivityContribution {
        .init(startTs: dayStart + Int(fromHour * 3_600), endTs: dayStart + Int(toHour * 3_600),
              kcal: kcal, source: source, isEstimated: estimated)
    }

    private func inputs(appleActive: Double? = nil, appleBasal: Double? = nil,
                        appleCoverage: Int? = nil,
                        strap: Double? = nil, coverage: Int? = nil,
                        calibration: Double? = nil,
                        uncertainty: Double? = nil,
                        calibrationStatus: EnergyCalibrationStatus = .off,
                        steps: Int? = nil, hoursWithSteps: Int? = nil,
                        stepHours: [Int]? = nil, strideM: Double? = nil,
                        sessions: [ActivityContribution] = []) -> EnergyEngine.DayInputs {
        .init(day: "2026-08-21", appleActiveKcal: appleActive,
              appleBasalKcal: appleBasal, appleCoverageSeconds: appleCoverage,
              strapTotalKcal: strap,
              strapCoverageSeconds: coverage, strapCalibrationFactor: calibration,
              strapUncertaintyFraction: uncertainty, calibrationStatus: calibrationStatus,
              steps: steps, hoursWithSteps: hoursWithSteps,
              stepHours: stepHours, strideM: strideM, loggedActivity: sessions)
    }

    /// What `stepActiveKcal` must produce for the canonical 10 000-step, 80 kg, unmeasured-stride day:
    /// 100 steps/min × 0.75 m = 4.5 km/h, which the shared curve prices at 3.3125 MET, over the
    /// 100 minutes those steps took. Written out rather than recomputed from the engine's own
    /// constants so a change to any of them fails here instead of agreeing with itself.
    private let tenThousandStepKcal = (3.3125 - 1) * 80 * (10_000.0 / 100 / 60)

    func testNoDataKeepsTotalUnknownButExposesBmrReference() {
        let summary = EnergyEngine.summarize(inputs(), profile: profile)
        XCTAssertEqual(summary.source, .profileOnly)
        XCTAssertNotNil(summary.estimatedBMR24h)
        XCTAssertNil(summary.totalBurnedSoFar)
        XCTAssertNil(summary.projectedTotalBurn)
    }

    func testBlankProfileCannotInventBmrOrTotal() {
        let blank = UserProfile(weightKg: 0, heightCm: 0, age: 0, sex: "nonbinary")
        let summary = EnergyEngine.summarize(inputs(), profile: blank)
        XCTAssertNil(summary.estimatedBMR24h)
        XCTAssertNil(summary.totalBurnedSoFar)
    }

    func testStrapWinsWhenAppleReferenceAlsoExistsWithoutAddingEitherSource() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, strap: 2_300, coverage: 86_400),
            profile: profile)
        XCTAssertEqual(summary.source, .strapWornTime)
        XCTAssertEqual(summary.totalBurnedSoFar, 2_300)
        XCTAssertEqual(summary.confidence, .solid)
    }

    func testAppleSplitRemainsCanonicalWithoutStrapEstimate() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800), profile: profile)
        XCTAssertEqual(summary.source, .appleSplit)
        XCTAssertEqual(summary.totalBurnedSoFar, 2_400)
    }

    // MARK: - Apple coverage (an `appleSplit` day is not automatically `.solid`)

    /// The regression this exists for: Apple reporting both active AND basal energy is not proof the
    /// source covered the whole elapsed day — only that it covered whatever it saw.
    func testAppleSplitWithThinCoverageIsNotAutomaticallySolid() {
        let thin = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, appleCoverage: 3_600),
            profile: profile, context: context(elapsed: 1, duration: 86_400))
        XCTAssertEqual(thin.source, .appleSplit)
        XCTAssertEqual(thin.coverage.energy ?? 0, 3_600.0 / 86_400.0, accuracy: 0.001)
        XCTAssertEqual(thin.confidence, .calibrating)
    }

    func testAppleSplitWithHighCoverageIsSolid() {
        let solid = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, appleCoverage: 80_000),
            profile: profile, context: context(elapsed: 1, duration: 86_400))
        XCTAssertEqual(solid.confidence, .solid)
    }

    /// The platform gap (macOS import, or any day before `healthEnergyBucket` existed) must NOT read
    /// as thin coverage — an ABSENT signal is not evidence of a THIN one, and marking every import
    /// down for a gap it didn't create would be a worse answer than staying silent about it.
    func testAppleSplitWithNoCoverageSignalStaysSolid() {
        let noSignal = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800), profile: profile)
        XCTAssertNil(noSignal.coverage.energy)
        XCTAssertEqual(noSignal.confidence, .solid)
    }

    /// WHOOP always wins when present (rule 1) — an Apple coverage figure on a day the strap also
    /// covered must not leak into the reported confidence.
    func testAppleCoverageIsIgnoredWhenStrapWins() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, appleCoverage: 100,
                  strap: 2_300, coverage: 86_400),
            profile: profile)
        XCTAssertEqual(summary.source, .strapWornTime)
        XCTAssertEqual(summary.confidence, .solid, "a thin Apple figure must not downgrade a solid strap day")
    }

    func testOptInCalibrationAppliesOnlyToWhoopAndIsDisclosed() {
        // Full-day coverage: observedBasal == bmr, so rawActive == strap - bmr exactly.
        let strap = EnergyEngine.summarize(
            inputs(appleActive: 900, appleBasal: 1_800, strap: 2_000,
                   coverage: 86_400, calibration: 1.1, uncertainty: 0.12,
                   calibrationStatus: .active), profile: profile)
        let rawActive = 2_000 - bmr
        XCTAssertEqual(strap.basalBurnedSoFar ?? 0, bmr, accuracy: 0.001,
                       "the calibration factor must not scale basal")
        XCTAssertEqual(strap.activeBurnedSoFar ?? 0, rawActive * 1.1, accuracy: 0.001,
                       "the calibration factor must scale ACTIVE energy, not the raw strap total")
        XCTAssertEqual(strap.totalBurnedSoFar ?? 0, bmr + rawActive * 1.1, accuracy: 0.001)
        XCTAssertEqual(strap.appliedCalibrationFactor, 1.1)
        XCTAssertEqual(strap.source, .strapWornTime)
        XCTAssertEqual(strap.rawWhoopTotalKcal, 2_000)
        XCTAssertEqual(strap.uncertaintyFraction, 0.12)
        XCTAssertEqual(strap.calibrationStatus, .active)

        let appleOnly = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, calibration: 1.1), profile: profile)
        XCTAssertEqual(appleOnly.totalBurnedSoFar, 2_400)
        XCTAssertNil(appleOnly.appliedCalibrationFactor)
    }

    /// A legacy strap total (no coverage denominator) cannot have its basal isolated, so the factor —
    /// fitted on active-only energy — must not be applied to the unsplit total at all.
    func testLegacyStrapTotalNeverReceivesTheActiveOnlyCalibrationFactor() {
        let summary = EnergyEngine.summarize(
            inputs(strap: 2_000, calibration: 1.1), profile: profile)
        XCTAssertEqual(summary.totalBurnedSoFar, 2_000)
        XCTAssertNil(summary.appliedCalibrationFactor)
        XCTAssertNil(summary.activeBurnedSoFar)
        XCTAssertNil(summary.basalBurnedSoFar)
    }

    func testInvalidCalibrationFactorIsIgnored() {
        for factor in [0.79, 1.21, .infinity, .nan] {
            let summary = EnergyEngine.summarize(
                inputs(strap: 2_000, coverage: 86_400, calibration: factor), profile: profile)
            XCTAssertEqual(summary.totalBurnedSoFar ?? 0, 2_000, accuracy: 0.001)
            XCTAssertNil(summary.appliedCalibrationFactor)
        }
    }

    func testStrapTopUpUsesRepresentedSecondsNotCaloriesDividedByBmr() {
        let covered = 10_800
        let strap = bmr * 0.125 + 700
        let summary = EnergyEngine.summarize(
            inputs(strap: strap, coverage: covered), profile: profile)
        XCTAssertEqual(summary.coverage.energy ?? 0, 0.125, accuracy: 0.001)
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, 700, accuracy: 1)
        XCTAssertEqual(summary.basalBurnedSoFar ?? 0, bmr, accuracy: 1)
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr + 700, accuracy: 1)
        XCTAssertEqual(summary.confidence, .calibrating)
    }

    func testLegacyStrapTotalIsPreservedWithoutInventedTopUpOrSplit() {
        let summary = EnergyEngine.summarize(inputs(strap: 900), profile: profile)
        XCTAssertEqual(summary.totalBurnedSoFar, 900)
        XCTAssertNil(summary.basalBurnedSoFar)
        XCTAssertNil(summary.activeBurnedSoFar)
        XCTAssertNil(summary.coverage.energy)
        XCTAssertEqual(summary.confidence, .building)
    }

    func testAppleActiveOnlyAtNoonAddsOnlyElapsedBasal() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 300), profile: profile,
            context: context(elapsed: 0.5, today: true))
        XCTAssertEqual(summary.basalBurnedSoFar ?? 0, bmr * 0.5, accuracy: 1)
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, 300 + bmr * 0.5, accuracy: 1)
        XCTAssertNil(summary.projectedTotalBurn)
        XCTAssertEqual(summary.forecastStatus, .learning)
    }

    func testProjectionExtrapolatesActiveEnergyAndAddsBmrOnce() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 300, appleBasal: bmr * 0.5), profile: profile,
            context: context(elapsed: 0.5, today: true))
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr * 0.5 + 300, accuracy: 1)
        XCTAssertNil(summary.projectedTotalBurn)
    }

    // MARK: - Personal day shape, TDEE prior, forecast interval

    private func shape(peakHours: [Int]) -> ActivityShape {
        var slots = [Double](repeating: 0, count: 24)
        for hour in peakHours { slots[hour] = 200 }
        let days = (0..<20).map { ActivityShapeEngine.DayProfile(
            day: String(format: "2026-07-%02d", $0 + 1), activeByHour: slots) }
        return ActivityShapeEngine.fit(days: days)!
    }

    func testWithoutHistoryForecastStaysInLearningInsteadOfExtrapolating() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 400,
                                            appleBasalKcal: 900)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let summary = EnergyEngine.summarize(inputs, profile: profile, context: context)
        XCTAssertNil(summary.projectedTotalBurn)
        XCTAssertEqual(summary.forecastStatus, .learning)
    }

    /// The defect this replaces: an 08:00 workout extrapolated linearly projects a fantastical day.
    /// A morning person's own curve knows the activity is nearly done, so the forecast stays sane.
    func testMorningWorkoutIsNotExtrapolatedAcrossTheWholeDay() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 600,
                                            appleBasalKcal: 300)
        // 09:00 — 37.5% of the day gone, but a morning person has banked nearly all their activity.
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 9 * 3_600)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [6, 7, 8]))
        let shapedValue = try XCTUnwrap(shaped.projectedTotalBurn)
        let oldLinear = 300 + bmr * (1 - 0.375) + 600 / 0.375
        XCTAssertLessThan(shapedValue, oldLinear - 500)
    }

    /// The mirror case: a quiet morning before an evening session must NOT be read as a quiet day.
    func testQuietMorningBeforeAnEveningRoutineIsNotUnderestimated() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 60,
                                            appleBasalKcal: 500)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 14 * 3_600)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [18, 19, 20]))
        XCTAssertGreaterThan(try XCTUnwrap(shaped.projectedTotalBurn), 500 + bmr * (10.0 / 24.0) + 60)
    }

    func testQuietMorningUsesHistoricalRemainderWithoutSixTimesExplosion() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 40,
                                            appleBasalKcal: 200)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 4 * 3_600)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [20, 21]))
        let bmr = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile))
        let ceiling = 240 + bmr + 500
        XCTAssertLessThanOrEqual(try XCTUnwrap(shaped.projectedTotalBurn), ceiling)
    }

    func testAdaptivePriorDoesNotRewriteTheWearableForecast() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        func projection(coverageSeconds: Int, prior: Double?) throws -> Double {
            let inputs = EnergyEngine.DayInputs(day: "2026-08-25", strapTotalKcal: 1_500,
                                                strapCoverageSeconds: coverageSeconds)
            return try XCTUnwrap(EnergyEngine.summarize(inputs, profile: profile, context: context,
                                                        shape: shape(peakHours: [7, 12, 18]),
                                                        adaptivePriorKcal: prior).projectedTotalBurn)
        }
        let thinBare = try projection(coverageSeconds: 3_600, prior: nil)
        let thinWithPrior = try projection(coverageSeconds: 3_600, prior: 2_400)
        XCTAssertEqual(thinWithPrior, thinBare, accuracy: 0.001)
        let fullBare = try projection(coverageSeconds: 43_000, prior: nil)
        let fullWithPrior = try projection(coverageSeconds: 43_000, prior: 2_400)
        XCTAssertEqual(fullWithPrior, fullBare, accuracy: 0.001)
    }

    /// An ABSENT coverage signal must read the same way everywhere. `confidence(...)` treats it as
    /// "trust it" (`.solid` — a macOS import didn't create the platform gap), so the prior blend must
    /// not simultaneously treat the very same nil as "distrust it" and pull the forecast halfway to a
    /// long-horizon average. Two contradictory readings of one nil in one file is the bug.
    func testUnknownCoverageIsReadTheSameWayByConfidenceAndThePriorBlend() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let noSignal = inputs(appleActive: 400, appleBasal: 900)
        let activity = shape(peakHours: [7, 12, 18])
        let bare = EnergyEngine.summarize(noSignal, profile: profile, context: context, shape: activity)
        let withPrior = EnergyEngine.summarize(noSignal, profile: profile, context: context,
                                               shape: activity,
                                               adaptivePriorKcal: 2_400)
        XCTAssertNil(bare.coverage.energy)
        XCTAssertEqual(bare.confidence, .solid)
        XCTAssertEqual(try XCTUnwrap(withPrior.projectedTotalBurn),
                       try XCTUnwrap(bare.projectedTotalBurn), accuracy: 0.001,
                       "an unknown coverage signal must not shrink a forecast the ladder calls solid")
    }

    func testKnownThinCoverageDoesNotLetAdaptiveEstimateTemperForecast() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let thin = inputs(appleActive: 400, appleBasal: 900, appleCoverage: 3_600)
        let activity = shape(peakHours: [7, 12, 18])
        let bare = EnergyEngine.summarize(thin, profile: profile, context: context, shape: activity)
        let withPrior = EnergyEngine.summarize(thin, profile: profile, context: context,
                                               shape: activity,
                                               adaptivePriorKcal: 2_400)
        XCTAssertEqual(try XCTUnwrap(withPrior.projectedTotalBurn),
                       try XCTUnwrap(bare.projectedTotalBurn), accuracy: 0.001)
    }

    /// A non-positive strap total is "no strap data" to `burn(...)` (it guards `strap > 0`), so every
    /// other reader must agree — otherwise an Apple-sourced day reports the strap's coverage and the
    /// WHOOP model's uncertainty alongside an Apple total.
    func testNonPositiveStrapTotalIsTreatedAsAbsentEverywhere() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 400, appleBasal: 900, appleCoverage: 80_000,
                   strap: 0, coverage: 3_600, uncertainty: 0.3),
            profile: profile, context: context(elapsed: 1, duration: 86_400))
        XCTAssertEqual(summary.source, .appleSplit)
        XCTAssertNil(summary.uncertaintyFraction,
                     "a WHOOP model uncertainty must not ride along on an Apple-sourced day")
        XCTAssertEqual(summary.coverage.energy ?? 0, 80_000.0 / 86_400.0, accuracy: 0.001,
                       "coverage must come from the source that actually produced the total")
    }

    /// The prior may temper the FORECAST, never the measurement.
    func testAdaptivePriorNeverTouchesWhatWasActuallyBurned() {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", strapTotalKcal: 1_500,
                                            strapCoverageSeconds: 3_600)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let bare = EnergyEngine.summarize(inputs, profile: profile, context: context)
        let withPrior = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                               adaptivePriorKcal: 2_400)
        XCTAssertEqual(withPrior.totalBurnedSoFar, bare.totalBurnedSoFar)
        XCTAssertEqual(withPrior.activeBurnedSoFar, bare.activeBurnedSoFar)
        XCTAssertEqual(withPrior.basalBurnedSoFar, bare.basalBurnedSoFar)
    }

    func testForecastCarriesAnIntervalThatWidensWithUncertainty() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        func width(uncertainty: Double) throws -> Double {
            let inputs = EnergyEngine.DayInputs(day: "2026-08-25", strapTotalKcal: 1_500,
                                                strapCoverageSeconds: 40_000,
                                                strapUncertaintyFraction: uncertainty)
            let range = try XCTUnwrap(EnergyEngine.summarize(
                inputs, profile: profile, context: context,
                shape: shape(peakHours: [7, 12, 18])).projectedRangeKcal)
            return range.upperBound - range.lowerBound
        }
        XCTAssertLessThan(try width(uncertainty: 0.05), try width(uncertainty: 0.35))
    }

    func testPastDayHasNeitherForecastNorInterval() {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-24", strapTotalKcal: 2_000,
                                            strapCoverageSeconds: 80_000)
        let summary = EnergyEngine.summarize(inputs, profile: profile, context: .completePastDay)
        XCTAssertNil(summary.projectedTotalBurn)
        XCTAssertNil(summary.projectedRangeKcal)
    }

    func testProjectionIsSuppressedVeryEarlyAndForPastDays() {
        let early = EnergyEngine.summarize(
            inputs(appleActive: 20, appleBasal: 60), profile: profile,
            context: context(elapsed: 0.06, today: true))
        XCTAssertNil(early.projectedTotalBurn)
        let past = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800), profile: profile,
            context: context(elapsed: 0.5, today: false))
        XCTAssertNil(past.projectedTotalBurn)
    }

    func testStepsFallbackUsesElapsedBasalAndMovementIsNotEnergyCoverage() {
        let summary = EnergyEngine.summarize(
            inputs(steps: 10_000, hoursWithSteps: 12), profile: profile,
            context: context(elapsed: 0.5, today: true))
        XCTAssertEqual(summary.source, .stepsEstimate)
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, tenThousandStepKcal, accuracy: 0.5)
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr * 0.5 + tenThousandStepKcal, accuracy: 1)
        XCTAssertEqual(summary.coverage.movement, 0.5)
        XCTAssertNil(summary.coverage.overall)
        XCTAssertEqual(summary.confidence, .calibrating)
    }

    /// The step estimate has to MOVE with the wearer, or the measured step length it now reads is
    /// decoration. A longer stride covers more ground per step, so the same count must cost more.
    func testMeasuredStrideRepricesTheSameStepCount() {
        let short = EnergyEngine.stepActiveKcal(steps: 10_000, strideM: 0.60, weightKg: 80) ?? 0
        let assumed = EnergyEngine.stepActiveKcal(steps: 10_000, strideM: nil, weightKg: 80) ?? 0
        let long = EnergyEngine.stepActiveKcal(steps: 10_000, strideM: 0.95, weightKg: 80) ?? 0
        XCTAssertLessThan(short, assumed)
        XCTAssertLessThan(assumed, long)
        // An implausible reading is not a stride; it falls back to the population figure rather than
        // pricing a 3 m step.
        XCTAssertEqual(EnergyEngine.stepActiveKcal(steps: 10_000, strideM: 3, weightKg: 80) ?? 0,
                       assumed, accuracy: 0.001)
        XCTAssertNil(EnergyEngine.stepActiveKcal(steps: 10_000, strideM: 0.75, weightKg: 0))
    }

    // MARK: - Logged sessions on a day no device measured

    func testLoggedSessionIsCountedWhenNothingMeasuredTheDay() {
        let summary = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context(elapsed: 1, today: false))
        XCTAssertEqual(summary.source, .loggedActivity)
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, 400, accuracy: 0.001)
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr + 400, accuracy: 0.001)
        // A logged hour is not a measured day: the card must not sound more certain for it.
        XCTAssertEqual(summary.confidence, .calibrating)
    }

    /// The strap/manual figure includes the bout's own resting energy, and the day already bills that
    /// through its basal top-up. Apple's does not. Same session, two sources, one hour apart in cost.
    func testGrossSessionLosesItsRestingShareAndNetSessionDoesNot() {
        let gross = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: 400, source: .whoop)]),
            profile: profile, context: context())
        let net = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: 400, source: .apple)]),
            profile: profile, context: context())
        XCTAssertEqual(gross.activeBurnedSoFar ?? 0, 400 - bmr / 24, accuracy: 0.001)
        XCTAssertEqual(net.activeBurnedSoFar ?? 0, 400, accuracy: 0.001)
    }

    /// An estimate NOOP produced is gross even in a lane that normally writes net energy: the table and
    /// the Keytel rate both price the whole window. The lane's convention describes what that lane
    /// WRITES, not what this app computes when the lane wrote nothing.
    func testAnEstimateIsGrossEvenInANetLane() {
        let summary = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: 400, source: .apple,
                                      estimated: true)]),
            profile: profile, context: context())
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, 400 - bmr / 24, accuracy: 0.001)
    }

    /// The overlap rule: a run is inside the step count as well as inside the session, so the step
    /// estimate is charged only for the hours no session covered.
    func testSessionHoursAreRemovedFromTheStepEstimate() {
        let hours = Array(8...19)   // twelve hours carrying steps
        let summary = EnergyEngine.summarize(
            inputs(steps: 10_000, hoursWithSteps: hours.count, stepHours: hours,
                   sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0,
                       400 + tenThousandStepKcal * 11 / 12, accuracy: 0.5)
    }

    func testWithoutHourlyStepsTheLargerEstimateStandsRatherThanTheSum() {
        let big = EnergyEngine.summarize(
            inputs(steps: 10_000, sessions: [session(fromHour: 9, toHour: 10, kcal: 900)]),
            profile: profile, context: context())
        XCTAssertEqual(big.activeBurnedSoFar ?? 0, 900, accuracy: 0.001)
        XCTAssertEqual(big.source, .loggedActivity)
        let small = EnergyEngine.summarize(
            inputs(steps: 10_000, sessions: [session(fromHour: 9, toHour: 10, kcal: 50)]),
            profile: profile, context: context())
        XCTAssertEqual(small.activeBurnedSoFar ?? 0, tenThousandStepKcal, accuracy: 0.5)
        // The step estimate won outright here, so the day may not be labelled as coming from a session
        // that contributed nothing to it.
        XCTAssertEqual(small.source, .stepsEstimate)
        XCTAssertNil(small.loggedActivityKcal)
    }

    /// "Does this count my workouts?" is answerable only by showing the part that came from them.
    func testTheSessionShareIsReportedSeparately() {
        let hours = Array(8...19)
        let recorded = EnergyEngine.summarize(
            inputs(steps: 10_000, hoursWithSteps: hours.count, stepHours: hours,
                   sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertEqual(recorded.loggedActivityKcal ?? 0, 400, accuracy: 0.001)
        XCTAssertFalse(recorded.loggedActivityIsEstimated)
        XCTAssertLessThan(recorded.loggedActivityKcal ?? 0, recorded.activeBurnedSoFar ?? 0)

        let modelled = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: 400, source: .hevy,
                                      estimated: true)]),
            profile: profile, context: context())
        XCTAssertTrue(modelled.loggedActivityIsEstimated)

        // A measured day's sessions are inside the measurement, so there is no separate share to show.
        let measured = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800,
                   sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertNil(measured.loggedActivityKcal)
    }

    /// A session that straddles midnight accrued its energy in both days, and each day may have only
    /// the share that happened inside it.
    func testSessionStraddlingMidnightIsSplitByTime() {
        let summary = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: -1, toHour: 1, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, 200, accuracy: 0.001)
    }

    /// "So far" has to mean so far. A session logged for later today is not energy anyone has spent.
    func testSessionBeyondTheElapsedEdgeIsNotCountedYet() {
        let summary = EnergyEngine.summarize(
            inputs(steps: 4_000, sessions: [session(fromHour: 18, toHour: 19, kcal: 400)]),
            profile: profile, context: context(elapsed: 0.5, today: true))
        XCTAssertEqual(summary.source, .stepsEstimate)
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0,
                       EnergyEngine.stepActiveKcal(steps: 4_000, strideM: nil, weightKg: 80) ?? 0,
                       accuracy: 0.001)
    }

    /// Without the day's absolute start no session can be placed in it. The engine says so by falling
    /// back to what it can still defend rather than guessing at the window.
    func testSessionsAreIgnoredWithoutADayStart() {
        let summary = EnergyEngine.summarize(
            inputs(steps: 4_000, sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context(withStart: false))
        XCTAssertEqual(summary.source, .stepsEstimate)
    }

    /// The rule that keeps every other branch honest applies here too: where a device DID measure the
    /// day, the sessions are already inside that measurement.
    func testSessionsDoNotTouchAMeasuredDay() {
        let strap = EnergyEngine.summarize(
            inputs(strap: 2_000, coverage: 43_200,
                   sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertEqual(strap.source, .strapWornTime)
        let apple = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800,
                   sessions: [session(fromHour: 9, toHour: 10, kcal: 400)]),
            profile: profile, context: context())
        XCTAssertEqual(apple.source, .appleSplit)
        XCTAssertEqual(apple.activeBurnedSoFar ?? 0, 600, accuracy: 0.001)
    }

    func testMalformedSessionsAreDroppedRatherThanClamped() {
        let summary = EnergyEngine.summarize(
            inputs(sessions: [session(fromHour: 9, toHour: 10, kcal: .nan),
                              session(fromHour: 9, toHour: 10, kcal: 40_000),
                              session(fromHour: 10, toHour: 10, kcal: 300),
                              session(fromHour: 11, toHour: 10, kcal: 300)]),
            profile: profile, context: context())
        XCTAssertEqual(summary.source, .profileOnly)
        XCTAssertNil(summary.totalBurnedSoFar)
    }

    func testRealDayDurationControlsCoverageAndBasalAccrual() {
        for duration in [82_800.0, 90_000.0] {
            let covered = Int(duration * 0.5)
            let summary = EnergyEngine.summarize(
                inputs(strap: bmr * 0.5, coverage: covered), profile: profile,
                context: context(elapsed: 0.5, duration: duration, today: true))
            XCTAssertEqual(summary.coverage.energy, 1)
            XCTAssertEqual(summary.basalBurnedSoFar ?? 0, bmr * 0.5, accuracy: 1)
        }
    }

    /// On a 23- or 25-hour day the strap total still carries `bmr / 86 400` per represented second
    /// (that is how the bucket model prices basal), so exactly that is what comes back out: a strap
    /// that measured nothing but basal leaves no active energy behind, whatever the day's length.
    func testTheStrapsOwnBasalIsRemovedAtTheRateItWasPricedAt() {
        for duration in [82_800.0, 86_400.0, 90_000.0] {
            let covered = duration * 0.5
            let summary = EnergyEngine.summarize(
                inputs(strap: bmr / 86_400 * covered, coverage: Int(covered)), profile: profile,
                context: context(elapsed: 0.5, duration: duration, today: true))
            XCTAssertEqual(summary.activeBurnedSoFar ?? -1, 0, accuracy: 0.01, "\(duration)")
        }
    }

    func testMalformedInputsAreRejected() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: .infinity, appleBasal: -1, strap: .nan,
                   coverage: -4, steps: 999_999), profile: profile)
        XCTAssertEqual(summary.source, .profileOnly)
        XCTAssertNil(summary.totalBurnedSoFar)
    }

    func testOutOfRangeCoverageDegradesToUnknown() {
        let summary = EnergyEngine.summarize(
            inputs(strap: bmr, coverage: 100_001), profile: profile)
        XCTAssertNil(summary.coverage.energy)
        XCTAssertEqual(summary.totalBurnedSoFar, bmr)
    }
}
