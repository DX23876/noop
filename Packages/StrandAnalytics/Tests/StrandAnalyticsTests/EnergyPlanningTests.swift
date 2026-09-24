import XCTest
@testable import StrandAnalytics

/// Pins the planning layer, whose defining property is what it refuses to claim.
final class EnergyPlanningTests: XCTestCase {

    private func day(_ n: Int, _ kcal: Double, _ source: EnergySource,
                     coverage: Double? = 0.9) -> BurnDay {
        BurnDay(day: String(format: "2026-09-%02d", n), totalKcal: kcal,
                source: source, coverage: coverage)
    }

    // MARK: - The formula page

    /// PAL is a multiplier on a basal rate, and the steps are the conventional ones.
    func testFormulaTdeeAppliesTheConventionalMultiplier() throws {
        XCTAssertEqual(try XCTUnwrap(EnergyPlanning.formulaTdee(basalKcal: 1_800,
                                                                activity: .moderate)),
                       1_800 * 1.55, accuracy: 1e-9)
        XCTAssertEqual(ActivityLevel.sedentary.factor, 1.2)
        XCTAssertEqual(ActivityLevel.veryHigh.factor, 1.9)
        XCTAssertNil(EnergyPlanning.formulaTdee(basalKcal: 0, activity: .moderate))
    }

    /// Every step is strictly greater than the one below it.
    func testTheActivityStepsIncreaseMonotonically() {
        let factors = ActivityLevel.allCases.map(\.factor)
        for (a, b) in zip(factors, factors.dropFirst()) { XCTAssertLessThan(a, b) }
    }

    // MARK: - Refusing to call a model a measurement

    /// Mostly measured days earn the label.
    func testMostlyMeasuredDaysEarnTheLabel() {
        let days = (1...10).map { day($0, 2_500, $0 <= 8 ? .strapWornTime : .stepsEstimate) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(burn.quality, .measured)
        XCTAssertEqual(burn.measuredDays, 8)
        XCTAssertEqual(burn.totalDays, 10)
    }

    /// THE rule from the spec: a 30-day mean of which most days are `stepsEstimate` is a formula
    /// calculation with extra steps, and must not be called measured.
    func testAMostlyModelledAverageIsNamedAsOne() {
        let days = (1...10).map { day($0, 2_500, $0 <= 2 ? .strapWornTime : .stepsEstimate) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(burn.quality, .mostlyModelled)
        XCTAssertEqual(burn.measuredDays, 2)
        XCTAssertEqual(burn.composition[.stepsEstimate], 8)
    }

    /// Between the two thresholds the answer is neither — reported as a mix rather than rounded to
    /// whichever label is closer.
    func testAGenuineMixIsReportedAsAMix() {
        let days = (1...10).map { day($0, 2_500, $0 <= 5 ? .strapWornTime : .stepsEstimate) }
        XCTAssertEqual(EnergyPlanning.measuredBurn(days: days).quality, .mixed)
    }

    /// `mixed` days are deliberately not counted as measured: part of that day was modelled.
    func testMixedSourceDaysDoNotCountAsMeasured() {
        let days = (1...10).map { day($0, 2_500, .mixed) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(burn.measuredDays, 0)
        XCTAssertEqual(burn.quality, .mostlyModelled)
        XCTAssertNil(burn.measuredMeanKcal)
        // The plain mean still exists — it is simply not called measured.
        XCTAssertEqual(try XCTUnwrap(burn.allDaysMeanKcal), 2_500, accuracy: 1e-9)
    }

    /// A barely-recorded day is not evidence of what that day cost, so it is excluded from the
    /// measured mean while still appearing in the composition.
    func testABarelyRecordedDayIsExcludedFromTheMeasuredMean() {
        let days = (1...10).map { day($0, 2_500, .strapWornTime, coverage: $0 <= 4 ? 0.2 : 0.9) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(burn.measuredDays, 6)
        XCTAssertEqual(burn.totalDays, 10)
    }

    /// The measured mean covers only measured days, so a cheap modelled day cannot drag it.
    func testTheMeasuredMeanIgnoresModelledDays() throws {
        let days = (1...4).map { day($0, $0 <= 2 ? 3_000 : 1_000,
                                     $0 <= 2 ? .strapWornTime : .stepsEstimate) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(try XCTUnwrap(burn.measuredMeanKcal), 3_000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(burn.allDaysMeanKcal), 2_000, accuracy: 1e-9)
    }

    /// A day whose coverage figure does not EXIST is not marked down for it. `EnergyCoverage` is
    /// explicit that an `appleSplit` day on a platform without the reference stream leaves this nil
    /// rather than being penalised for a platform gap it did not create — and reading nil as zero once
    /// produced "0 of 30 days were measured" beside a composition saying all 30 came from Apple.
    func testAnAbsentCoverageFigureDoesNotDisqualifyADay() throws {
        let days = (1...30).map { day($0, 2_400, .appleSplit, coverage: nil) }
        let burn = EnergyPlanning.measuredBurn(days: days)
        XCTAssertEqual(burn.measuredDays, 30)
        XCTAssertEqual(burn.quality, .measured)
        XCTAssertEqual(try XCTUnwrap(burn.measuredMeanKcal), 2_400, accuracy: 1e-9)
    }

    /// A coverage figure that EXISTS and is poor still disqualifies — the distinction is between
    /// unknown and known-bad, not between present and absent.
    func testAKnownPoorCoverageStillDisqualifies() {
        let days = (1...10).map { day($0, 2_400, .appleSplit, coverage: 0.1) }
        XCTAssertEqual(EnergyPlanning.measuredBurn(days: days).measuredDays, 0)
    }

    /// No days at all produces nothing, not a zero.
    func testNoDaysProduceNothing() {
        let burn = EnergyPlanning.measuredBurn(days: [])
        XCTAssertNil(burn.measuredMeanKcal)
        XCTAssertNil(burn.allDaysMeanKcal)
        XCTAssertEqual(burn.totalDays, 0)
    }

    // MARK: - The corridor

    /// The spread is the product: three numbers and the distance between the extremes.
    func testTheCorridorReportsTheSpreadBetweenExtremes() throws {
        let corridor = EnergyCorridor(formulaKcal: 2_400, measuredKcal: 2_650, balanceKcal: 2_500)
        XCTAssertEqual(try XCTUnwrap(corridor.spreadKcal), 250, accuracy: 1e-9)
        XCTAssertEqual(corridor.present, [2_400, 2_500, 2_650])
    }

    /// Two figures still make a corridor; one does not.
    func testOneFigureIsNotASpread() throws {
        XCTAssertEqual(try XCTUnwrap(EnergyCorridor(formulaKcal: 2_400, measuredKcal: 2_650,
                                                    balanceKcal: nil).spreadKcal),
                       250, accuracy: 1e-9)
        XCTAssertNil(EnergyCorridor(formulaKcal: 2_400, measuredKcal: nil,
                                    balanceKcal: nil).spreadKcal)
        XCTAssertNil(EnergyCorridor(formulaKcal: nil, measuredKcal: nil, balanceKcal: nil).spreadKcal)
    }

    // MARK: - From TDEE to a plan

    /// The Wishnofsky convention, and its inverse, round-trip.
    func testTheConventionAndItsInverseRoundTrip() throws {
        let delta = try XCTUnwrap(EnergyPlanning.dailyEnergyDelta(targetKgPerWeek: -0.5))
        XCTAssertEqual(delta, -550, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(EnergyPlanning.weeklyRate(dailyDeltaKcal: delta)),
                       -0.5, accuracy: 1e-9)
        XCTAssertEqual(EnergyPlanning.wishnofskyKcalPerKg, 7_700)
    }

    /// The wearer's own observed cost per kilogram, computed from what actually happened.
    func testTheObservedCostPerKilogramComesFromWhatHappened() throws {
        // Ate 2 000/day, burned 2 500/day for 30 days = 15 000 kcal deficit; lost 1.8 kg.
        let value = try XCTUnwrap(EnergyPlanning.observedKcalPerKg(
            intakeKcal: 2_000 * 30, burnKcal: 2_500 * 30, weightChangeKg: -1.8))
        XCTAssertEqual(value, 15_000 / 1.8, accuracy: 1e-6)
    }

    /// Too little weight change and the quotient explodes, so the answer is silence rather than a
    /// confident absurdity.
    func testTooLittleWeightChangeProducesNothing() {
        XCTAssertNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 60_000, burnKcal: 75_000,
                                                      weightChangeKg: -0.1))
        XCTAssertNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 60_000, burnKcal: 75_000,
                                                      weightChangeKg: 0))
    }

    /// A result far outside the plausible band means the inputs disagree — an unlogged week, or a
    /// different scale — and is refused rather than reported.
    func testAnImplausibleResultIsRefused() {
        XCTAssertNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 60_000, burnKcal: 60_500,
                                                      weightChangeKg: -5))
        XCTAssertNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 60_000, burnKcal: 200_000,
                                                      weightChangeKg: -5))
    }

    /// A LOW result is the water-loss artefact, and it is the one that actually showed up on screen:
    /// a small deficit divided by a weight swing that was mostly water printed "2 344 kcal per
    /// kilogram" beside the 7 700 convention as though it were this person's own metabolism.
    func testAWaterDrivenWeightSwingIsRefused() {
        // 30 days at a 100 kcal deficit, against 1.3 kg off the scale — 2 300 kcal/kg.
        XCTAssertNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 2_200 * 30, burnKcal: 2_300 * 30,
                                                      weightChangeKg: -1.3))
        // The same deficit against a credible loss still answers.
        XCTAssertNotNil(EnergyPlanning.observedKcalPerKg(intakeKcal: 2_000 * 30,
                                                         burnKcal: 2_500 * 30,
                                                         weightChangeKg: -1.8))
        XCTAssertEqual(EnergyPlanning.plausibleKcalPerKg, 4_000...15_000)
    }

    // MARK: - Thermic effect of food

    func testThermicEffectFallsBackToTheMixedDietFigureWithoutMacros() {
        XCTAssertEqual(EnergyPlanning.thermicEffect(intakeKcal: 2_500) ?? 0,
                       250, accuracy: 0.001)
        // An unlogged day has no known intake, and zero would claim it did.
        XCTAssertNil(EnergyPlanning.thermicEffect(intakeKcal: nil))
        XCTAssertNil(EnergyPlanning.thermicEffect(intakeKcal: 0))
        XCTAssertNil(EnergyPlanning.thermicEffect(intakeKcal: .nan))
    }

    func testThermicEffectFollowsTheMacroSplit() {
        // Same calories, two diets: the protein-heavy one must cost more to digest, which is the only
        // reason to read macros at all.
        let protein = EnergyPlanning.thermicEffect(intakeKcal: 2_000, proteinG: 200, carbsG: 150,
                                                   fatG: 66) ?? 0
        let fat = EnergyPlanning.thermicEffect(intakeKcal: 2_000, proteinG: 60, carbsG: 150,
                                               fatG: 120) ?? 0
        XCTAssertGreaterThan(protein, fat)
        // Split into typed parts: as one literal expression the CI toolchain's type checker timed out.
        let proteinPart: Double = 200 * 4 * 0.25
        let carbPart: Double = 150 * 4 * 0.08
        let fatPart: Double = 66 * 9 * 0.04
        let byHand = proteinPart + carbPart + fatPart
        XCTAssertEqual(protein, byHand, accuracy: 0.01)
        // A partial log still counts what it knows rather than falling back to the flat figure.
        let proteinOnly: Double = 150 * 4 * 0.25
        XCTAssertEqual(EnergyPlanning.thermicEffect(intakeKcal: 2_000, proteinG: 150) ?? 0,
                       proteinOnly, accuracy: 0.01)
    }

    func testThermicEffectCannotExceedTheMealItCameFrom() {
        // Grams and calories disagreeing is ordinary (rounding, a hand-typed entry, a lossy import).
        // It must not be able to invent a digestion cost larger than the food.
        let absurd = EnergyPlanning.thermicEffect(intakeKcal: 100, proteinG: 900) ?? 0
        XCTAssertEqual(absurd, 100 * EnergyPlanning.thermicFractionProtein, accuracy: 0.001)
    }

    // MARK: - Today's balance

    private func balance(intake: Double? = 2_000, thermic: Double? = 200,
                         burn: Double? = 2_500, range: ClosedRange<Double>? = nil)
        -> EnergyPlanning.DailyBalance? {
        EnergyPlanning.dailyBalance(intakeKcal: intake, thermicKcal: thermic,
                                    projectedBurnKcal: burn, projectedBurnRange: range)
    }

    func testDigestionCountsOnTheSpendingSide() {
        // The thermic effect is deliberately kept OUT of the measured burn — no wearable measures
        // digestion. A balance is a calculation either way, and leaving it out would understate
        // every deficit by roughly a tenth of the intake.
        let withThermic = balance(intake: 2_000, thermic: 200, burn: 2_500)
        XCTAssertEqual(withThermic?.expenditureKcal, 2_700)
        XCTAssertEqual(withThermic?.balanceKcal, -700)
        XCTAssertEqual(balance(intake: 2_000, thermic: nil, burn: 2_500)?.balanceKcal, -500)
    }

    func testTheVerdictUsesABandProportionalToTheDay() {
        // 5 % of 2,700 is 135, so ±135 kcal is holding steady rather than a direction.
        XCTAssertEqual(balance(intake: 2_650, burn: 2_500)?.verdict, .maintenance)
        XCTAssertEqual(balance(intake: 2_560, burn: 2_500)?.verdict, .deficit)
        XCTAssertEqual(balance(intake: 2_840, burn: 2_500)?.verdict, .surplus)
        XCTAssertEqual(balance(intake: 2_650, burn: 2_500)?.maintenanceBandKcal ?? 0, 135,
                       accuracy: 0.001)
    }

    func testAForecastThatStillAllowsBothDirectionsGivesNoVerdict() {
        // Midday: the day could end at 2,000 or at 3,000 burned, so "deficit" would be a coin toss
        // that flips by evening.
        let undecided = balance(intake: 2_400, thermic: 200, burn: 2_500, range: 2_000...3_000)
        XCTAssertEqual(undecided?.verdict, .tooEarly)
        // Once the whole range lands on one side, it says so.
        let settled = balance(intake: 2_400, thermic: 200, burn: 2_900, range: 2_800...3_000)
        XCTAssertEqual(settled?.verdict, .deficit)
    }

    func testTheBalanceRangeIsTheBurnRangeInverted() {
        // A bigger burn is a more negative balance; getting this backwards would put the optimistic
        // end where the pessimistic one belongs.
        let b = balance(intake: 2_400, thermic: 200, burn: 2_500, range: 2_000...3_000)
        XCTAssertEqual(b?.range?.lowerBound ?? 0, 2_400 - 3_200, accuracy: 0.001)
        XCTAssertEqual(b?.range?.upperBound ?? 0, 2_400 - 2_200, accuracy: 0.001)
    }

    func testHalfTheInputsGiveNoVerdictAtAll() {
        // "You are in a deficit", computed against a burn nobody projected, is a sentence with one
        // number in it.
        XCTAssertNil(balance(intake: nil))
        XCTAssertNil(balance(burn: nil))
        XCTAssertNil(balance(intake: 0))
        XCTAssertNil(balance(intake: .nan))
    }
}
