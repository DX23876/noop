import XCTest
@testable import StrandAnalytics

final class EnergyEngineTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
    private var bmr: Double { Calories.bmrKcalPerDay(profile: profile) ?? 0 }

    private func context(elapsed fraction: Double = 1, duration: Double = 86_400,
                         today: Bool = false) -> EnergyEngine.DayContext {
        .init(isToday: today, dayDurationSeconds: duration, elapsedSeconds: duration * fraction)
    }

    private func inputs(appleActive: Double? = nil, appleBasal: Double? = nil,
                        appleCoverage: Int? = nil,
                        strap: Double? = nil, coverage: Int? = nil,
                        calibration: Double? = nil,
                        uncertainty: Double? = nil,
                        calibrationStatus: EnergyCalibrationStatus = .off,
                        steps: Int? = nil, hoursWithSteps: Int? = nil) -> EnergyEngine.DayInputs {
        .init(day: "2026-08-21", appleActiveKcal: appleActive,
              appleBasalKcal: appleBasal, appleCoverageSeconds: appleCoverage,
              strapTotalKcal: strap,
              strapCoverageSeconds: coverage, strapCalibrationFactor: calibration,
              strapUncertaintyFraction: uncertainty, calibrationStatus: calibrationStatus,
              steps: steps, hoursWithSteps: hoursWithSteps)
    }

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

    func testStrapTopUpUsesObservedSecondsNotCaloriesDividedByBmr() {
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
        XCTAssertEqual(summary.projectedTotalBurn ?? 0, bmr + 600, accuracy: 1)
    }

    func testProjectionExtrapolatesActiveEnergyAndAddsBmrOnce() {
        let summary = EnergyEngine.summarize(
            inputs(appleActive: 300, appleBasal: bmr * 0.5), profile: profile,
            context: context(elapsed: 0.5, today: true))
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr * 0.5 + 300, accuracy: 1)
        XCTAssertEqual(summary.projectedTotalBurn ?? 0, bmr + 600, accuracy: 1)
    }

    // MARK: - Personal day shape, TDEE prior, forecast interval

    private func shape(peakHours: [Int]) -> ActivityShape {
        var slots = [Double](repeating: 0, count: 24)
        for hour in peakHours { slots[hour] = 200 }
        let days = (0..<20).map { ActivityShapeEngine.DayProfile(
            day: String(format: "2026-07-%02d", $0 + 1), activeByHour: slots) }
        return ActivityShapeEngine.fit(days: days)!
    }

    /// The formula must COLLAPSE to the previous arithmetic when no shape applies — algebraically
    /// identical, not merely close, so a user without history sees no change at all.
    func testWithoutAShapeTheProjectionIsBitIdenticalToTheLinearModel() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 400,
                                            appleBasalKcal: 900)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let summary = EnergyEngine.summarize(inputs, profile: profile, context: context)
        let bmr = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile))
        // The old expression for an appleSplit day: basal + bmr*(1-f) + active/f.
        XCTAssertEqual(try XCTUnwrap(summary.projectedTotalBurn),
                       900 + bmr * 0.5 + 400 / 0.5, accuracy: 0.0001)
    }

    /// The defect this replaces: an 08:00 workout extrapolated linearly projects a fantastical day.
    /// A morning person's own curve knows the activity is nearly done, so the forecast stays sane.
    func testMorningWorkoutIsNotExtrapolatedAcrossTheWholeDay() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 600,
                                            appleBasalKcal: 300)
        // 09:00 — 37.5% of the day gone, but a morning person has banked nearly all their activity.
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 9 * 3_600)
        let linear = EnergyEngine.summarize(inputs, profile: profile, context: context)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [6, 7, 8]))
        let linearValue = try XCTUnwrap(linear.projectedTotalBurn)
        let shapedValue = try XCTUnwrap(shaped.projectedTotalBurn)
        XCTAssertLessThan(shapedValue, linearValue,
                          "a curve that says the activity is already done must lower the forecast")
        // Linear credits 600/0.375 = 1600 active; the shape credits close to the 600 actually burned.
        XCTAssertLessThan(shapedValue, linearValue - 500)
    }

    /// The mirror case: a quiet morning before an evening session must NOT be read as a quiet day.
    func testQuietMorningBeforeAnEveningRoutineIsNotUnderestimated() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 60,
                                            appleBasalKcal: 500)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 14 * 3_600)
        let linear = EnergyEngine.summarize(inputs, profile: profile, context: context)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [18, 19, 20]))
        XCTAssertGreaterThan(try XCTUnwrap(shaped.projectedTotalBurn),
                             try XCTUnwrap(linear.projectedTotalBurn))
    }

    /// The multiplier is clamped: a near-zero point on the curve must not turn a few kcal at dawn
    /// into a five-figure day.
    func testRemainingActivityMultiplierIsClamped() throws {
        let inputs = EnergyEngine.DayInputs(day: "2026-08-25", appleActiveKcal: 40,
                                            appleBasalKcal: 200)
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 4 * 3_600)
        let shaped = EnergyEngine.summarize(inputs, profile: profile, context: context,
                                            shape: shape(peakHours: [20, 21]))
        let bmr = try XCTUnwrap(Calories.bmrKcalPerDay(profile: profile))
        let ceiling = 240 + bmr + 40 * EnergyEngine.maxRemainingActivityMultiplier
        XCTAssertLessThanOrEqual(try XCTUnwrap(shaped.projectedTotalBurn), ceiling)
    }

    /// The prior tempers a thinly-covered forecast, and drops out entirely once the day is well seen.
    func testAdaptivePriorShrinksAThinlyCoveredForecastButNotAWellCoveredOne() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        func projection(coverageSeconds: Int, prior: Double?) throws -> Double {
            let inputs = EnergyEngine.DayInputs(day: "2026-08-25", strapTotalKcal: 1_500,
                                                strapCoverageSeconds: coverageSeconds)
            return try XCTUnwrap(EnergyEngine.summarize(inputs, profile: profile, context: context,
                                                        adaptivePriorKcal: prior).projectedTotalBurn)
        }
        // Barely-covered day: the prior pulls the forecast down toward measured maintenance.
        let thinBare = try projection(coverageSeconds: 3_600, prior: nil)
        let thinWithPrior = try projection(coverageSeconds: 3_600, prior: 2_400)
        XCTAssertLessThan(thinWithPrior, thinBare)
        // Well-covered day: full sensor weight, prior contributes nothing.
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
        let bare = EnergyEngine.summarize(noSignal, profile: profile, context: context)
        let withPrior = EnergyEngine.summarize(noSignal, profile: profile, context: context,
                                               adaptivePriorKcal: 2_400)
        XCTAssertNil(bare.coverage.energy)
        XCTAssertEqual(bare.confidence, .solid)
        XCTAssertEqual(try XCTUnwrap(withPrior.projectedTotalBurn),
                       try XCTUnwrap(bare.projectedTotalBurn), accuracy: 0.001,
                       "an unknown coverage signal must not shrink a forecast the ladder calls solid")
    }

    /// A KNOWN-thin Apple day is the case the prior actually exists for, and must still shrink.
    func testKnownThinCoverageStillLetsThePriorTemperTheForecast() throws {
        let context = EnergyEngine.DayContext(isToday: true, dayDurationSeconds: 86_400,
                                              elapsedSeconds: 43_200)
        let thin = inputs(appleActive: 400, appleBasal: 900, appleCoverage: 3_600)
        let bare = EnergyEngine.summarize(thin, profile: profile, context: context)
        let withPrior = EnergyEngine.summarize(thin, profile: profile, context: context,
                                               adaptivePriorKcal: 2_400)
        XCTAssertLessThan(try XCTUnwrap(withPrior.projectedTotalBurn),
                          try XCTUnwrap(bare.projectedTotalBurn))
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
                inputs, profile: profile, context: context).projectedRangeKcal)
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
        let active = 10_000.0 * EnergyEngine.kcalPerStepPerKg * 80
        XCTAssertEqual(summary.activeBurnedSoFar ?? 0, active, accuracy: 1)
        XCTAssertEqual(summary.totalBurnedSoFar ?? 0, bmr * 0.5 + active, accuracy: 1)
        XCTAssertEqual(summary.coverage.movement, 0.5)
        XCTAssertNil(summary.coverage.overall)
        XCTAssertEqual(summary.confidence, .calibrating)
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
