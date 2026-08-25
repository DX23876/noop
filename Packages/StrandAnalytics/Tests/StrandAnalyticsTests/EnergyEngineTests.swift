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
                        strap: Double? = nil, coverage: Int? = nil,
                        calibration: Double? = nil,
                        steps: Int? = nil, hoursWithSteps: Int? = nil) -> EnergyEngine.DayInputs {
        .init(day: "2026-08-21", appleActiveKcal: appleActive,
              appleBasalKcal: appleBasal, strapTotalKcal: strap,
              strapCoverageSeconds: coverage, strapCalibrationFactor: calibration,
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

    func testOptInCalibrationAppliesOnlyToWhoopAndIsDisclosed() {
        let strap = EnergyEngine.summarize(
            inputs(appleActive: 900, appleBasal: 1_800, strap: 2_000,
                   coverage: 86_400, calibration: 1.1), profile: profile)
        XCTAssertEqual(strap.totalBurnedSoFar ?? 0, 2_200, accuracy: 0.001)
        XCTAssertEqual(strap.appliedCalibrationFactor, 1.1)
        XCTAssertEqual(strap.source, .strapWornTime)

        let appleOnly = EnergyEngine.summarize(
            inputs(appleActive: 600, appleBasal: 1_800, calibration: 1.1), profile: profile)
        XCTAssertEqual(appleOnly.totalBurnedSoFar, 2_400)
        XCTAssertNil(appleOnly.appliedCalibrationFactor)
    }

    func testInvalidCalibrationFactorIsIgnored() {
        for factor in [0.79, 1.21, .infinity, .nan] {
            let summary = EnergyEngine.summarize(
                inputs(strap: 2_000, coverage: 86_400, calibration: factor), profile: profile)
            XCTAssertEqual(summary.totalBurnedSoFar, 2_000)
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
