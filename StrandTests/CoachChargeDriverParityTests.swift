import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The coach's Charge breakdown must describe the SAME terms the Today sheet does. It didn't: the
/// rest-quality (sleep-performance) term was passed as `nil`, on the documented assumption that it
/// needed the app's merged/carried resolution and so was unreachable from the engine. It isn't —
/// `AnalyticsEngine.Rest.composite(daily:)` is pure and row-local — and the nil silently dropped a whole
/// row from the coach's answer, letting it explain a Charge differently from the screen the user is
/// looking at.
@MainActor
final class CoachChargeDriverParityTests: XCTestCase {

    /// A night with enough sleep detail for `Rest.composite` to resolve — that's what the term needs.
    private func night(_ day: String,
                       hrv: Double,
                       rhr: Int,
                       sleepMin: Double? = 430,
                       efficiency: Double? = 0.92,
                       recovery: Double? = 62) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleepMin, efficiency: efficiency,
                    deepMin: 95, remMin: 105, lightMin: 230, disturbances: 6,
                    restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: 9.0, exerciseCount: 1)
    }

    /// Enough history that the HRV baseline folds to `usable` — the breakdown gates on it. Ends
    /// YESTERDAY, so a test that appends its own "today" row doesn't collide with a generated one.
    private func history(count: Int = 30) -> [DailyMetric] {
        (0..<count).map { i in
            let date = Calendar.current.date(byAdding: .day, value: -(count - i), to: Date())!
            return night(Repository.logicalDayKey(date), hrv: 62 + Double(i % 5), rhr: 52)
        }
    }

    // MARK: - The term itself

    func testRestQualityTermIsTheRestCompositeOverHundred() {
        let daily = night("2026-07-21", hrv: 60, rhr: 50)
        let expected = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 }

        XCTAssertNotNil(expected, "fixture must actually resolve a composite, or this proves nothing")
        XCTAssertEqual(AICoachEngine.restQualityTerm(daily), expected,
                       "must be the SAME derivation IntelligenceEngine.recomputeRecovery used to write "
                       + "the stored Charge")
    }

    func testRestQualityTermFallsBackToRawEfficiency() {
        // No sleep minutes → no composite. The stored score falls back to raw efficiency; so must this.
        let daily = night("2026-07-21", hrv: 60, rhr: 50, sleepMin: nil)
        XCTAssertEqual(AICoachEngine.restQualityTerm(daily), 0.92)
    }

    func testRestQualityTermIsNilWhenNothingIsKnown() {
        let daily = night("2026-07-21", hrv: 60, rhr: 50, sleepMin: nil, efficiency: nil)
        XCTAssertNil(AICoachEngine.restQualityTerm(daily),
                     "a missing input must produce no term, never a fabricated one")
    }

    // MARK: - The breakdown actually carries the row now

    func testBreakdownIncludesTheRestTerm() {
        let days = history()
        let repo = Repository(deviceId: "test-charge-parity-\(UUID().uuidString)")
        repo.days = days
        let engine = AICoachEngine(repo: repo)

        let block = engine.chargeDriversBlock()

        // Cross-check against the driver list computed WITH the term: whatever label the analytics
        // package gives the rest term, it must appear in the coach's text.
        let hrvBase = Baselines.foldHistory(days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        let expected = RecoveryScorer.chargeDrivers(
            hrv: days.last!.avgHrv!, rhr: Double(days.last!.restingHr!), resp: days.last!.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: AICoachEngine.restQualityTerm(days.last!), skinTempDev: days.last!.skinTempDevC)
        let withoutTerm = RecoveryScorer.chargeDrivers(
            hrv: days.last!.avgHrv!, rhr: Double(days.last!.restingHr!), resp: days.last!.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: days.last!.skinTempDevC)

        XCTAssertGreaterThan(expected.count, withoutTerm.count,
                             "fixture guard: the term must add a row, or the regression is untestable")
        guard let restRow = expected.first(where: { row in !withoutTerm.contains { $0.label == row.label } })
        else { return XCTFail("could not identify the added rest row") }

        XCTAssertTrue(block.contains(restRow.label),
                      "the coach dropped the '\(restRow.label)' row the Today sheet shows. Got:\n\(block)")
    }

    // MARK: - Row selection: the carry, so a rollover morning doesn't diverge either

    func testUnscoredTodayCarriesTheLastScoredNight() {
        var days = history()
        let todayKey = Repository.logicalDayKey(Date())
        days.append(night(todayKey, hrv: 61, rhr: 51, recovery: nil))   // today, not scored yet

        let row = AICoachEngine.chargeBreakdownRow(days: days, todayKey: todayKey)

        XCTAssertNotNil(row?.recovery,
                        "Today's ring carries the last SCORED night at the rollover; answering 'not "
                        + "enough data' while the screen shows a number is the same divergence")
        XCTAssertNotEqual(row?.day, todayKey)
    }

    func testScoredTodayWinsOverTheCarry() {
        var days = history()
        let todayKey = Repository.logicalDayKey(Date())
        days.append(night(todayKey, hrv: 70, rhr: 48, recovery: 80))

        XCTAssertEqual(AICoachEngine.chargeBreakdownRow(days: days, todayKey: todayKey)?.day, todayKey,
                       "once today is scored it is the row, never a stale carry")
    }

    func testNoHistoryIsHandled() {
        XCTAssertNil(AICoachEngine.chargeBreakdownRow(days: [], todayKey: "2026-07-21"))
    }
}
