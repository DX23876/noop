import XCTest
@testable import StrandAnalytics

/// RecoveryForecaster — evening estimate of tomorrow-morning Charge. The oracle for the
/// Android RecoveryForecastTest; keep the two in lockstep.
final class RecoveryForecastTests: XCTestCase {

    // A steady baseline: 14 nights all at Charge 60, Effort 50.
    private let steadyCharge = Array(repeating: 60.0, count: 14)
    private let steadyEffort = Array(repeating: 50.0, count: 14)

    // MARK: - Gating

    func testNilUntilEnoughBaseline() {
        // Below minBaselineNights → no forecast (honest cold-start).
        let few = Array(repeating: 60.0, count: RecoveryForecaster.minBaselineNights - 1)
        XCTAssertNil(RecoveryForecaster.forecast(recentCharge: few, todayEffort: 50,
                                                 plannedSleepHours: 8))
        // Exactly at the gate → a forecast appears.
        let enough = Array(repeating: 60.0, count: RecoveryForecaster.minBaselineNights)
        XCTAssertNotNil(RecoveryForecaster.forecast(recentCharge: enough, todayEffort: nil,
                                                    plannedSleepHours: 8))
    }

    func testEmptyChargeIsNil() {
        XCTAssertNil(RecoveryForecaster.forecast(recentCharge: [], todayEffort: 50,
                                                 plannedSleepHours: 8))
    }

    // MARK: - Neutral case anchors to the baseline

    func testNeutralDayLandsNearBaseline() {
        // Today's Effort == recent average, sleep == need → only tiny reversion (slope 0
        // on a flat series), so the forecast sits on the baseline mean (60).
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: steadyEffort,
                                            todayEffort: 50,
                                            plannedSleepHours: RecoveryForecaster.defaultNeedHours)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.baseline, 60, accuracy: 1e-9)
        XCTAssertEqual(f!.charge, 60, accuracy: 1e-9)   // flat slope → no reversion nudge
        XCTAssertEqual(f!.nights, 14)
    }

    // MARK: - Strain debt

    func testHarderDayLowersForecast() {
        // A much harder-than-average day suppresses tomorrow's Charge.
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: steadyEffort,
                                            todayEffort: 80,   // +30 over the avg of 50
                                            plannedSleepHours: RecoveryForecaster.defaultNeedHours)!
        XCTAssertLessThan(f.charge, 60)
    }

    func testEasierDayRaisesForecast() {
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: steadyEffort,
                                            todayEffort: 20,   // −30 under the avg
                                            plannedSleepHours: RecoveryForecaster.defaultNeedHours)!
        XCTAssertGreaterThan(f.charge, 60)
    }

    func testStrainAdjIsCapped() {
        // A freak max-Effort day cannot remove more than strainAdjCap points.
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: steadyEffort,
                                            todayEffort: 100,
                                            plannedSleepHours: RecoveryForecaster.defaultNeedHours)!
        // Only the strain term moves here (sleep == need, slope 0).
        XCTAssertGreaterThanOrEqual(f.charge, 60 - RecoveryForecaster.strainAdjCap)
    }

    func testStrainTermDropsWithoutEffortHistory() {
        // No recent Effort → strain term is silent; neutral sleep keeps us on baseline.
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: [],
                                            todayEffort: 100,
                                            plannedSleepHours: RecoveryForecaster.defaultNeedHours)!
        XCTAssertEqual(f.charge, 60, accuracy: 1e-9)
    }

    // MARK: - Sleep adequacy

    func testShortSleepLowersForecast() {
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge,
                                            recentEffort: steadyEffort,
                                            todayEffort: 50,
                                            plannedSleepHours: 4)!   // half the 8 h need
        XCTAssertLessThan(f.charge, 60)
    }

    func testOversleepHelpIsCapped() {
        // Sleeping far beyond need does not keep adding Charge (diminishing returns).
        let plenty = RecoveryForecaster.forecast(recentCharge: steadyCharge, recentEffort: steadyEffort,
                                                 todayEffort: 50, plannedSleepHours: 12)!
        let justOver = RecoveryForecaster.forecast(recentCharge: steadyCharge, recentEffort: steadyEffort,
                                                   todayEffort: 50, plannedSleepHours: 10)!
        XCTAssertEqual(plenty.charge, justOver.charge, accuracy: 1e-9)
    }

    func testNegativeSleepTreatedAsZero() {
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge, recentEffort: steadyEffort,
                                            todayEffort: 50, plannedSleepHours: -3)!
        XCTAssertEqual(f.plannedSleepHours, 0, accuracy: 1e-9)
    }

    // MARK: - Output bounds

    func testChargeAndBandStayInRange() {
        // Drive everything negative: low baseline, brutal Effort, no sleep.
        let low = Array(repeating: 8.0, count: 14)
        let f = RecoveryForecaster.forecast(recentCharge: low, recentEffort: steadyEffort,
                                            todayEffort: 100, plannedSleepHours: 0)!
        XCTAssertGreaterThanOrEqual(f.charge, 0)
        XCTAssertLessThanOrEqual(f.charge, 100)
        XCTAssertGreaterThanOrEqual(f.low, 0)
        XCTAssertLessThanOrEqual(f.high, 100)
    }

    // MARK: - Band + confidence

    func testThinBaselineWidensBandAndIsBuilding() {
        let thin = Array(repeating: 60.0, count: 6)   // < trustedNights (10)
        let f = RecoveryForecaster.forecast(recentCharge: thin, recentEffort: steadyEffort,
                                            todayEffort: 50, plannedSleepHours: 8)!
        // Flat series SD == 0, so band == floor + thin inflation.
        XCTAssertEqual(f.band, RecoveryForecaster.minBandPoints + RecoveryForecaster.thinBandPoints,
                       accuracy: 1e-9)
        XCTAssertEqual(f.confidence, .building)
    }

    func testFullBaselineWithInformedNeedIsSolid() {
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge, recentEffort: steadyEffort,
                                            todayEffort: 50, plannedSleepHours: 8,
                                            needNights: RecoveryForecaster.solidNeedNights)!
        XCTAssertEqual(f.confidence, .solid)
        // 14 nights ≥ trustedNights → no thin inflation; flat SD → just the floor.
        XCTAssertEqual(f.band, RecoveryForecaster.minBandPoints, accuracy: 1e-9)
    }

    func testFullBaselineButDefaultNeedIsBuilding() {
        // Enough Charge nights but the sleep need is still the unrefined default.
        let f = RecoveryForecaster.forecast(recentCharge: steadyCharge, recentEffort: steadyEffort,
                                            todayEffort: 50, plannedSleepHours: 8, needNights: 0)!
        XCTAssertEqual(f.confidence, .building)
    }

    // MARK: - Mean reversion

    func testDownswingIsDamped() {
        // A steady downward streak: the forecast should sit ABOVE a naive last-value read,
        // pulled back toward the baseline by the reversion term.
        let falling = stride(from: 80.0, through: 54.0, by: -2.0).map { $0 }  // 14 pts, mean 67
        let f = RecoveryForecaster.forecast(recentCharge: falling, recentEffort: steadyEffort,
                                            todayEffort: 50, plannedSleepHours: 8)!
        XCTAssertGreaterThan(f.charge, falling.last!)   // not just extrapolating the slump
    }

    // MARK: - Stat helpers

    func testStatHelpers() {
        XCTAssertEqual(RecoveryForecaster.mean([2, 4, 6]), 4, accuracy: 1e-9)
        XCTAssertEqual(RecoveryForecaster.mean([]), 0, accuracy: 1e-9)
        XCTAssertEqual(RecoveryForecaster.sampleSD([10]), 0, accuracy: 1e-9)
        // SD of [2,4,6] with ddof=1 is 2.
        XCTAssertEqual(RecoveryForecaster.sampleSD([2, 4, 6]), 2, accuracy: 1e-9)
        // Perfect +1/day ramp → slope 1.
        XCTAssertEqual(RecoveryForecaster.leastSquaresSlope([1, 2, 3, 4]), 1, accuracy: 1e-9)
        XCTAssertEqual(RecoveryForecaster.leastSquaresSlope([5]), 0, accuracy: 1e-9)
    }

    func testClampPreservesInputSignedZeroAtInclusiveBounds() {
        // Cross-platform contract (#56): a value numerically equal to either bound is
        // already in range, so clamp returns x itself and preserves x's IEEE sign bit.
        let cases: [(x: Double, lo: Double, hi: Double)] = [
            (+0.0, -0.0, 1.0),
            (-0.0, +0.0, 1.0),
            (+0.0, -1.0, -0.0),
            (-0.0, -1.0, +0.0),
        ]
        for value in cases {
            XCTAssertEqual(
                RecoveryForecaster.clamp(value.x, value.lo, value.hi).bitPattern,
                value.x.bitPattern
            )
        }

        XCTAssertEqual(RecoveryForecaster.clamp(-1.01, -1.0, 1.0), -1.0)
        XCTAssertEqual(RecoveryForecaster.clamp(0.25, -1.0, 1.0), 0.25)
        XCTAssertEqual(RecoveryForecaster.clamp(1.01, -1.0, 1.0), 1.0)
    }
}
