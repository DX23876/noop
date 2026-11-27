import XCTest
@testable import StrandAnalytics

final class EnergyRangeTests: XCTestCase {
    private func summary(total: Double?, uncertainty: Double?, scale: Double? = nil) -> DailyEnergySummary {
        DailyEnergySummary(day: "2026-12-01", estimatedBMR24h: 2_900, basalBurnedSoFar: 2_900, activeBurnedSoFar: 600,
                           totalBurnedSoFar: total, projectedTotalBurn: nil, uncertaintyFraction: uncertainty,
                           source: .strapWornTime, coverage: EnergyCoverage(energy: 1, movement: 1, hasStrapEstimate: true),
                           confidence: .solid, scaleCorrectionFactor: scale)
    }

    /// The strap's own error and the formula's miss for one body, added as independent errors.
    func testAFinishedDayNamesWhereItLikelyLies() throws {
        let likely = try XCTUnwrap(EnergyRange.likely(summary(total: 4_400, uncertainty: 0.10), isToday: false))
        let relative = (0.10 * 0.10 + 0.10 * 0.10).squareRoot()
        XCTAssertEqual(likely.low, 4_400 * (1 - relative), accuracy: 1e-6)
        XCTAssertEqual(likely.high, 4_400 * (1 + relative), accuracy: 1e-6)
        XCTAssertFalse(likely.narrowedByScale)
        let wide = try XCTUnwrap(EnergyRange.likely(summary(total: 4_400, uncertainty: 0.5), isToday: false))
        XCTAssertEqual(wide.high, 4_400 * 1.3, accuracy: 1e-6, "never wider than 30 %")
    }

    func testTheScaleNarrowsItAndTodayKeepsItsForecast() throws {
        let scaled = try XCTUnwrap(EnergyRange.likely(summary(total: 4_400, uncertainty: 0.10, scale: 1.08), isToday: false))
        XCTAssertEqual(scaled.high - scaled.low, 4_400 * 0.10, accuracy: 1e-6)
        XCTAssertTrue(scaled.narrowedByScale)
        XCTAssertNil(EnergyRange.likely(summary(total: 4_400, uncertainty: 0.10), isToday: true))
        XCTAssertNil(EnergyRange.likely(summary(total: nil, uncertainty: 0.10), isToday: false))
    }
}
