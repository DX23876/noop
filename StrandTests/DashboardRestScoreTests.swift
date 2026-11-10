import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import Strand

final class DashboardRestScoreTests: XCTestCase {
    func testCorrectedDailySleepIsUsedBeforeMetricSeriesCatchesUp() throws {
        let day = "2026-09-07"
        let corrected = DailyMetric(
            day: day, totalSleepMin: 450, efficiency: 0.94,
            deepMin: 100, remMin: 110, lightMin: 240, disturbances: 2,
            restingHr: 50, avgHrv: 70, recovery: 80, strain: 8,
            exerciseCount: 1, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)

        let result = try XCTUnwrap(DashboardRestScore.value(
            day: day, days: [corrected], importedSleep: [:], restTraits: .empty))

        XCTAssertEqual(result, AnalyticsEngine.Rest.composite(daily: corrected, inputs: .coldStart))
    }

    /// AI-35: a night's Rest uses the need stored for it, the one the pass scored it with.
    func testTheNightsStoredNeedIsUsed() throws {
        let day = "2026-09-07"
        let night = DailyMetric(
            day: day, totalSleepMin: 450, efficiency: 0.94,
            deepMin: 100, remMin: 110, lightMin: 240, disturbances: 2,
            restingHr: 50, avgHrv: 70, recovery: 80, strain: 8,
            exerciseCount: 1, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        let traits = RestTraitLookup(needMinByDay: [day: 540], consistencyPctByDay: [day: 75])
        let result = try XCTUnwrap(DashboardRestScore.value(day: day, days: [night], importedSleep: [:],
                                                            restTraits: traits))
        XCTAssertEqual(result, AnalyticsEngine.Rest.composite(
            daily: night, inputs: .init(needHours: 9, consistency: 0.75)))
        XCTAssertLessThan(result, try XCTUnwrap(DashboardRestScore.value(day: day, days: [night], importedSleep: [:],
                                                                          restTraits: .empty)))
    }

    func testImportedPerformanceRemainsAuthoritative() {
        let day = "2026-09-07"
        var imported = ImportedSleepFigures()
        imported.performancePct = 87
        XCTAssertEqual(DashboardRestScore.value(day: day, days: [],
                                                importedSleep: [day: imported], restTraits: .empty), 87)
    }
}
