import XCTest
import WhoopStore
@testable import Strand

/// Pins the day's step figure to ONE rule.
///
/// Overview shipped with a shorter version of TodayView's rule — strap counter, then Apple Health, and
/// nothing after that. A WHOOP 4.0 sends no step counter, so on a day with no same-day Apple row the tile
/// had nothing to show, while Today showed the on-device estimate for the same day. The rule (#843/#813)
/// is now one function; these tests are what keep a third, shorter copy from appearing.
final class DailyStepsReadingTests: XCTestCase {

    func testStrapCounterWinsOverEveryOtherSource() {
        let reading = DailyStepsReading.resolve(strapSteps: 8_100, appleSteps: 7_400, estimatedSteps: 6_000)
        XCTAssertEqual(reading, .measured(8_100))
        XCTAssertFalse(reading?.isEstimated ?? true)
    }

    func testAppleHealthFillsInForAStrapThatCannotCount() {
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: nil, appleSteps: 7_400, estimatedSteps: 6_000),
                       .measured(7_400))
    }

    /// The gap a WHOOP 4.0 user would otherwise see as "—". The estimate fills it, and is marked.
    func testEstimateIsUsedLastAndIsMarkedAsAnEstimate() {
        let reading = DailyStepsReading.resolve(strapSteps: nil, appleSteps: nil, estimatedSteps: 6_000)
        XCTAssertEqual(reading, .estimated(6_000))
        XCTAssertTrue(reading?.isEstimated ?? false)
        XCTAssertEqual(reading?.steps, 6_000)
    }

    /// No source for THIS day means no number. The rule must not reach for the newest row it has — that
    /// is the stale-import bug the rule exists to prevent, and it is the caller's job to pass same-day
    /// values, so the honest answer here is nil rather than a fabricated one.
    func testNoSameDaySourceMeansNoReading() {
        XCTAssertNil(DailyStepsReading.resolve(strapSteps: nil, appleSteps: nil, estimatedSteps: nil))
    }

    /// A real zero is a real answer — a day with no steps recorded by a strap that DOES count is 0, not
    /// "fall through to the estimate".
    func testAMeasuredZeroIsNotTreatedAsMissing() {
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: 0, appleSteps: nil, estimatedSteps: 6_000),
                       .measured(0))
        XCTAssertEqual(DailyStepsReading.resolve(strapSteps: nil, appleSteps: 0, estimatedSteps: 6_000),
                       .measured(0))
    }
}

/// Pins the OTHER rule — the one that looks like the opposite of the steps rule, and is.
///
/// Fitness age, VO₂max and Vitality are slow-moving banked estimates: the engine writes a new one when it
/// has enough to say, which is not every day. TodayView reads them as "the latest banked value"; the two
/// dashboards asked for the value dated exactly to the selected day, so they printed "—" on every day the
/// estimate had not been rewritten — which is most days, and is what a wearer reported seeing.
final class LatestBankedTests: XCTestCase {

    private let series: [(day: String, value: Double)] = [
        (day: "2026-08-01", value: 38),
        (day: "2026-08-20", value: 36),
    ]

    /// Today: the newest banked estimate, matching what TodayView shows for the same wearer.
    func testTodayTakesTheNewestBankedEstimate() {
        XCTAssertEqual(latestBanked(series, asOf: "2026-09-02"), 36)
    }

    /// The day the estimate was actually written still resolves to it — `<=`, not `<`.
    func testTheBankingDayItselfCounts() {
        XCTAssertEqual(latestBanked(series, asOf: "2026-08-20"), 36)
    }

    /// A navigated past day gets the estimate as it stood THEN, never one banked afterwards. This is
    /// where a plain "newest value" would be wrong, and why the rule is anchored to the selected day.
    func testAPastDayNeverSeesALaterEstimate() {
        XCTAssertEqual(latestBanked(series, asOf: "2026-08-10"), 38)
    }

    /// Before anything was banked there is nothing to say, and the card renders its honest "—".
    func testNothingBankedYetIsNil() {
        XCTAssertNil(latestBanked(series, asOf: "2026-07-31"))
        XCTAssertNil(latestBanked([], asOf: "2026-09-02"))
    }

    /// The two rules are deliberately opposite, and must stay that way: a step count belongs to its day,
    /// so reaching for the newest row is the bug there — a fitness age does not, so refusing to is the
    /// bug here. Same data shape, opposite correct answers.
    func testTheStepsRuleAndTheBankedRuleDisagreeOnPurpose() {
        // No same-day step source: the steps rule says nothing rather than reaching back.
        XCTAssertNil(DailyStepsReading.resolve(strapSteps: nil, appleSteps: nil, estimatedSteps: nil))
        // No same-day estimate: the banked rule reaches back, because that IS the current estimate.
        XCTAssertEqual(latestBanked(series, asOf: "2026-09-02"), 36)
    }
}

/// Pins the per-field vitals carry the dashboard cards use.
///
/// Blood Oxygen was the reported symptom: the two dashboards printed "—" while Today showed a number for
/// the same day. The column is sparse by construction — the engine writes `spo2Pct = nil` for WHOOP 5/MG
/// entirely, and computed rows write it nil even when an imported row holds a real reading — so reading
/// only today's row answers a different question than the wearer is asking.
final class DashboardVitalCarryTests: XCTestCase {

    private func row(_ day: String, spo2: Double? = nil, resp: Double? = nil,
                     skinTempDev: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skinTempDev,
                    respRateBpm: resp)
    }

    func testTodaysOwnValueAlwaysWins() {
        let carry = DashboardVitalCarry(vitals: row("2026-09-01", spo2: 90), spo2: row("2026-08-20", spo2: 80))
        XCTAssertEqual(carry.spo2Pct(row("2026-09-02", spo2: 97)), 97)
    }

    /// The whole-row vitals carry is tried before the per-field one, matching Today's order.
    func testCarryFallsBackWholeRowThenPerField() {
        let carry = DashboardVitalCarry(vitals: row("2026-09-01", spo2: 95), spo2: row("2026-08-20", spo2: 80))
        XCTAssertEqual(carry.spo2Pct(row("2026-09-02")), 95)

        // The whole-row carry lands on a row whose spo2 is nil — the case the per-field carry exists for.
        let sparse = DashboardVitalCarry(vitals: row("2026-09-01"), spo2: row("2026-08-20", spo2: 80))
        XCTAssertEqual(sparse.spo2Pct(row("2026-09-02")), 80)
    }

    /// Respiration is measured every night, so its carry is the staleness-bounded one and it does NOT use
    /// the whole-row carry — #1331, where unbounded resolvers printed one import's value for a fortnight.
    func testRespiratoryUsesOnlyItsOwnBoundedCarry() {
        let carry = DashboardVitalCarry(vitals: row("2026-09-01", resp: 15.6), resp: nil)
        XCTAssertNil(carry.respRateBpm(row("2026-09-02")))
        XCTAssertEqual(carry.respRateBpm(row("2026-09-02", resp: 13.7)), 13.7)
    }

    /// A navigated past day shows its own row verbatim: carrying into the past would print a value
    /// recorded AFTER the day being read.
    func testAPastDayCarriesNothing() {
        let days = [row("2026-08-20", spo2: 80), row("2026-09-01", spo2: 95)]
        let carry = DashboardVitalCarry.resolve(days: days, todayKey: "2026-08-25", isToday: false)
        XCTAssertNil(carry.spo2Pct(row("2026-08-25")))
    }

    /// Nothing anywhere is still "—", never a fabricated reading.
    func testNoReadingAnywhereStaysEmpty() {
        XCTAssertNil(DashboardVitalCarry().spo2Pct(row("2026-09-02")))
        XCTAssertNil(DashboardVitalCarry().skinTempDevC(row("2026-09-02")))
    }
}
