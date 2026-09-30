import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Swift twin of the Android `RecoveryDriversUiTest` wiring cases.
///
/// This suite could not exist before: the derivation lived as a private method inside `TodayView` (and a
/// byte-identical copy inside `CoupledView`), reachable only by rendering the view, so the iOS end of the
/// "What shaped it" path had no test at all while Android's did. `ChargeBreakdownWiring.breakdown` is that
/// derivation lifted out unchanged. Since #2525 it scores against `Repository.chargeBaselines`, the
/// baselines `ChargeBaselines.resolve` builds with the engine's own rule, so these cases resolve first.
///
/// Case mapping against the Kotlin suite, stated so the gap is legible rather than implied:
///   * `rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable` - twinned below.
///   * `coldStartHistoryProducesNoRows` - twinned below.
///   * `scoredDayProducesDriverRows` - twinned below, and it carries the confidence assertion too, since
///     this API returns the tier in the same tuple where Kotlin has a separate `chargeConfidenceTier`.
///   * `nullDayProducesNoRows` - deliberately NOT twinned. This API takes a non-optional row, so the
///     nil-row guard stays in the view where it belongs; there is nothing here to assert.
final class ChargeBreakdownWiringTests: XCTestCase {

    private func day(_ d: String, hrv: Double? = 55, rhr: Int? = 55, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 450, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: nil,
                    exerciseCount: nil)
    }

    /// The breakdown for `row` against own nights `days` (plus `imported`), anchored on `row`'s day.
    private func breakdown(_ days: [DailyMetric], imported: [DailyMetric] = [], row: DailyMetric,
                           hrvEpoch: Double = 0) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        let baselines = ChargeBaselines.resolve(imported: imported, own: days, anchorDay: row.day,
                                                hrvEpoch: hrvEpoch, recoveryEpoch: 0)
        return ChargeBreakdownWiring.breakdown(baselines: baselines, row: row, sleepPerfPercent: 85)
    }

    /// A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
    /// which is nobody's resting HR, so the row must be absent. The HRV row still stands, since that
    /// baseline is real. The display day itself carries a reading, so this pins the BASELINE being
    /// unusable rather than the reading being missing.
    ///
    /// The gate is not in this file: `RecoveryScorer.chargeDrivers` applies it (#1990). This pins the end
    /// of the path, the surface a user actually sees.
    func testRhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        let history = (1...6).map { day(String(format: "2026-01-%02d", $0), rhr: nil) }
        let today = day("2026-01-07", rhr: 55)
        let out = breakdown(history + [today], row: today)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"),
                      "the HRV baseline is real, so its row must still be there: \(labels)")
        XCTAssertFalse(labels.contains("Resting heart rate"),
                       "no usable resting-HR baseline, so no RHR row: \(labels)")
    }

    /// Two nights only: the HRV baseline is not usable yet, so there are no honest drivers and the sheet
    /// hides rather than showing fabricated rows.
    func testColdStartHistoryProducesNoBreakdown() {
        let days = [day("2026-01-01"), day("2026-01-02")]
        XCTAssertNil(breakdown(days, row: days[1]))
    }

    /// The usable-baseline half of the pair: a real history banks both baselines, so both rows appear and
    /// the surfaced tier is past calibrating.
    func testAScoredDayProducesDriverRowsAndATier() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let out = breakdown(past + [today], row: today)
        XCTAssertNotNil(out)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"), "\(labels)")
        XCTAssertTrue(labels.contains("Resting heart rate"), "\(labels)")
        XCTAssertNotEqual(out?.confidence, .calibrating)
    }

    /// Epoch for a `yyyy-MM-dd` key at UTC midnight, matching what Recalibrate writes.
    private func epochOf(_ day: String) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return date.timeIntervalSince1970
    }

    func testDriverBaselineHonoursTheRecalibrationEpoch() {
        // The reported shape: low-HRV history, Recalibrate, then higher nights. Folding the WHOLE history
        // gives one baseline and folding from the epoch gives another, and the headline uses the second.
        // These rows have to agree with the headline rather than with history.
        //
        // Asserted on `baselineText` because that is what a Swift ChargeDriver carries: it pre-formats for
        // display where the Kotlin twin keeps a numeric `baseline`. Different text is the observable proof
        // that a different history was folded.
        let old = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 40) }
        let since = (11...20).map { day(String(format: "2026-01-%02d", $0), hrv: 70) }
        let today = day("2026-01-21", hrv: 72, recovery: 70)
        let days = old + since + [today]

        let whole = breakdown(days, row: today, hrvEpoch: 0)
        let fromEpoch = breakdown(days, row: today, hrvEpoch: epochOf("2026-01-11"))
        let hrvRow: ((drivers: [ChargeDriver], confidence: ScoreConfidence)?) -> ChargeDriver? = { out in
            out?.drivers.first(where: { $0.label == "Heart rate variability" })
        }
        guard let w = hrvRow(whole), let r = hrvRow(fromEpoch) else {
            return XCTFail("both folds must produce an HRV row")
        }
        XCTAssertNotEqual(w.baselineText, r.baselineText,
                          "the epoch fold must discard the pre-recalibration nights, so the baseline it "
                          + "reports differs from the whole-history one (whole=\(w.baselineText), "
                          + "fromEpoch=\(r.baselineText))")
    }

    /// #2525: once the own nights are trusted on their own, the import no longer takes part in the
    /// baseline the headline is scored against, so the rows must not move with it either. Before #2525 the
    /// rows folded every imported night and could read a baseline the score never used.
    func testAnImportTheHeadlineNoLongerUsesDoesNotMoveTheRows() {
        let own = (1...20).map { day(String(format: "2026-01-%02d", $0), hrv: 70 + Double($0 % 3)) }
        let today = day("2026-01-21", hrv: 72, recovery: 70)
        // Inside the window and on the same days: only the handoff can keep it out of the baseline.
        let lowImport = (1...20).map { day(String(format: "2026-01-%02d", $0), hrv: 40) }
        let alone = breakdown(own + [today], row: today)
        let withImport = breakdown(own + [today], imported: lowImport, row: today)
        XCTAssertEqual(alone?.drivers.map(\.baselineText), withImport?.drivers.map(\.baselineText))
        XCTAssertEqual(alone?.drivers.map(\.deltaPoints), withImport?.drivers.map(\.deltaPoints))
    }
}
