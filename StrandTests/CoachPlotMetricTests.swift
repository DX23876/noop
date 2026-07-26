import XCTest
import WhoopStore
@testable import Strand

/// Pins T3.6 of Etappe T: `plot_metric` widened from five hardcoded metric names to any metric key the
/// user has data for (validated against `Repository.availableKeys`). The five hand-named metrics still
/// read straight off `repo.days` (no store hit) so they stay testable without a database; the new
/// fallback branch needs a real store and isn't covered here (no store-seeding test seam exists in this
/// codebase — see the equivalent note on the T3.2 sleep-detail tests).
@MainActor
final class CoachPlotMetricTests: XCTestCase {

    private func makeEngine(days: [DailyMetric]) -> AICoachEngine {
        let repo = Repository(deviceId: "test-plot-metric-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    private func day(_ dayStr: String, avgHrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: avgHrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    func testHumanizeMetricKeyTitleCasesEachUnderscoreSegment() {
        XCTAssertEqual(AICoachEngine.humanizeMetricKey("sleep_performance"), "Sleep Performance")
        XCTAssertEqual(AICoachEngine.humanizeMetricKey("spo2"), "Spo2")
        XCTAssertEqual(AICoachEngine.humanizeMetricKey(""), "")
    }

    /// Regression: the five hand-named metrics still work end-to-end after `chartArtifact` /
    /// `handlePlotMetric` became `async` to support the new fallback branch.
    func testKnownMetricStillProducesAChart() async {
        let days = (1...5).map { day("2026-01-0\($0)", avgHrv: 50 + Double($0)) }
        let engine = makeEngine(days: days)
        let result = await engine.handlePlotMetric(metric: "hrv", days: 30)
        XCTAssertTrue(result.contains("Displayed a chart of HRV"), "got: \(result)")
    }

    func testKnownMetricWithTooLittleDataReportsNoData() async {
        let engine = makeEngine(days: [day("2026-01-01", avgHrv: 50)])   // one point, chart needs >= 2
        let result = await engine.handlePlotMetric(metric: "hrv", days: 30)
        XCTAssertEqual(result, "No data available to plot \"hrv\".")
    }
}
