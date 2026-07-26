import XCTest
import WhoopStore
@testable import Strand

/// P15: verifies the trend tools (`get_range_report`, `get_zone_minutes`) are correctly wired end-to-end
/// and that the flows meant to use them for a multi-day judgement — the weekly review — actually direct
/// the model to call them, rather than leaving intensity verification to chance. `get_range_report` was
/// already directed in P10; the gap this closes is `get_zone_minutes`, whose own tool description says
/// to verify a prescribed intensity was actually hit, but nothing previously told the model WHEN to
/// reach for it.
@MainActor
final class CoachTrendToolingTests: XCTestCase {

    private func makeEngine(days: [DailyMetric] = []) -> AICoachEngine {
        let repo = Repository(deviceId: "test-trend-tooling-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    private func day(_ dayStr: String, avgHrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: avgHrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: - weeklyReviewInstruction now directs get_zone_minutes too (#P15 16.2)

    func testWeeklyReviewWithToolsDirectsAllThreeTrendTools() {
        let text = AICoachEngine.weeklyReviewInstruction(toolsActive: true)
        XCTAssertTrue(text.contains("get_range_report"), "already required since P10")
        XCTAssertTrue(text.contains("get_plan_adherence"), "already required since P10")
        XCTAssertTrue(text.contains("get_zone_minutes"),
                      "closes P15's gap: intensity actually hit, not assumed from a 'done' status")
    }

    func testWeeklyReviewAsksForTheTrendNotASingleDay() {
        // 16.1: "keine oberflächlichen Einzelwert-Kommentare" — pin the explicit anti-superficiality line.
        let text = AICoachEngine.weeklyReviewInstruction(toolsActive: true)
        XCTAssertTrue(text.contains("grounded in the trend across the week, not one day"))
    }

    func testWeeklyReviewWithoutToolsNamesNoTools() {
        // Mirrors the brief/check-in split: a provider without tool-calling must never be told to call
        // something that isn't on the wire.
        let text = AICoachEngine.weeklyReviewInstruction(toolsActive: false)
        XCTAssertFalse(text.contains("get_range_report"))
        XCTAssertFalse(text.contains("get_plan_adherence"))
        XCTAssertFalse(text.contains("get_zone_minutes"))
    }

    // MARK: - get_range_report is a genuine trend read, not a single value (#P15 16.1)

    func testRangeReportComparesFirstAndSecondHalfOfTheWindow() async {
        // Rising HRV across the window: the report's per-metric line must show a first→second-half
        // comparison, not just a bare mean — that's what makes it a TREND, not one number.
        let days = (1...10).map { day("2026-01-\(String(format: "%02d", $0))", avgHrv: 40 + Double($0) * 2) }
        let engine = makeEngine(days: days)
        let report = await engine.rangeReportTool(days: 10)
        XCTAssertTrue(report.contains("RANGE REPORT"))
        XCTAssertTrue(report.contains("→"), "must show a first→second-half comparison, not a single figure")
    }

    func testRangeReportClampsAnOutOfRangeWindowInsteadOfCrashing() async {
        let days = (1...5).map { day("2026-01-0\($0)", avgHrv: 45) }
        let engine = makeEngine(days: days)
        // Way outside the documented 7–365 range; must clamp, never crash or misbehave.
        let tooSmall = await engine.rangeReportTool(days: 0)
        let tooLarge = await engine.rangeReportTool(days: 100_000)
        XCTAssertFalse(tooSmall.isEmpty)
        XCTAssertFalse(tooLarge.isEmpty)
    }

    func testRangeReportWithTooFewDaysReportsHonestly() async {
        let engine = makeEngine(days: [day("2026-01-01", avgHrv: 45)])
        let report = await engine.rangeReportTool(days: 30)
        XCTAssertEqual(report, "Not enough recorded days for a range report yet.")
    }

    // MARK: - get_zone_minutes fails honestly without workout HR data (no store-seeding test seam here,

    /// same documented limitation as `CoachPlotMetricTests`'s fallback branch): confirms it never crashes
    /// and returns the exact fallback line its own tool description promises the model.
    func testZoneMinutesWithNoWorkoutDataReportsHonestly() async {
        let engine = makeEngine()
        let result = await engine.zoneMinutesTool(days: 7)
        XCTAssertEqual(result, "No workout heart-rate data in the last 7 days to compute zone minutes.")
    }
}
