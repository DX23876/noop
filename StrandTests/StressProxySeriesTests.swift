import XCTest
import WhoopStore
@testable import Strand

/// Pins `IntelligenceEngine.stressProxyRows(days:)` (#R-stress-chart) — the daily 0-3 stress-proxy
/// persistence that lets `plot_metric` chart "stress" for the first time. Must match `StressMath`'s own
/// formula exactly (same z-score + squash `StressView` uses live), since a chart and the Stress screen
/// must never disagree — including `StressModel`'s own rule that a day with no baseline behind it (no
/// prior days carrying RHR/HRV) gets no score at all, never a fabricated neutral value.
final class StressProxySeriesTests: XCTestCase {

    private func day(_ dayStr: String, restingHr: Int? = nil, avgHrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: restingHr, avgHrv: avgHrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testFirstDayHasNoBaselineSoNoRowIsProduced() {
        // Matches `StressModel.init`'s own rule: with zero prior days, `meanRHR`/`meanHRV` are nil, so
        // `derivedAvailable` is false and the day gets no score — never a fabricated neutral value.
        let rows = IntelligenceEngine.stressProxyRows(days: [day("2026-01-01", restingHr: 55, avgHrv: 60)], cut: .none)
        XCTAssertTrue(rows.isEmpty)
    }

    func testADayWithNoRHROrHRVIsSkippedEvenWithAnEstablishedBaseline() {
        var days = (1...5).map { day("2026-01-0\($0)", restingHr: 50, avgHrv: 70) }
        days.append(day("2026-01-06"))   // no signal at all
        let rows = IntelligenceEngine.stressProxyRows(days: days, cut: .none)
        XCTAssertFalse(rows.contains { $0.day == "2026-01-06" })
    }

    func testMatchesStressMathDirectlyOverARollingBaseline() {
        // 5 baseline days with a touch of natural variance (a constant baseline has zero std deviation,
        // which zeroes both z-score terms outright — real nights always vary a little), then one day with
        // RHR up / HRV down — should read stressed (> 1.5), matching a hand-computed StressMath call over
        // the exact same baseline window.
        let baselineRHR = [49, 50, 51, 50, 50]
        let baselineHRV: [Double] = [68, 70, 72, 70, 69]
        var days = zip(1...5, zip(baselineRHR, baselineHRV)).map { i, rh in
            day("2026-01-0\(i)", restingHr: rh.0, avgHrv: rh.1)
        }
        days.append(day("2026-01-06", restingHr: 62, avgHrv: 50))

        let rows = IntelligenceEngine.stressProxyRows(days: days, cut: .none)
        guard let today = rows.first(where: { $0.day == "2026-01-06" }) else {
            return XCTFail("expected a stress row for the scored day")
        }

        let baseline = Array(days[0..<5])
        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }
        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV = StressMath.std(hrvBase, mean: meanHRV)
        let expectedRaw = StressMath.rawScore(rhrToday: 62, meanRHR: meanRHR, sdRHR: sdRHR,
                                              hrvToday: 50, meanHRV: meanHRV, sdHRV: sdHRV)
        let expected = StressMath.squash(expectedRaw)

        XCTAssertEqual(today.value, expected, accuracy: 0.0001)
        XCTAssertGreaterThan(today.value, 1.5, "an RHR-up/HRV-down day should read more stressed than baseline")
    }

    func testEveryRowStaysWithinTheZeroToThreeRange() {
        var days = (1...5).map { day("2026-02-0\($0)", restingHr: 48, avgHrv: 90) }
        days.append(day("2026-02-06", restingHr: 90, avgHrv: 20))   // an extreme outlier day
        let rows = IntelligenceEngine.stressProxyRows(days: days, cut: .none)
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.value, 0)
            XCTAssertLessThanOrEqual(row.value, 3)
        }
    }

    func testEachRowIsKeyedStress() {
        var days = (1...5).map { day("2026-03-0\($0)", restingHr: 50, avgHrv: 70) }
        days.append(day("2026-03-06", restingHr: 55, avgHrv: 65))
        let rows = IntelligenceEngine.stressProxyRows(days: days, cut: .none)
        XCTAssertTrue(rows.allSatisfy { $0.key == "stress" })
    }

    // MARK: - Recalibration (AI-28)

    /// 20 nights at an old HRV level of 90 ms, a recalibration, then nights around 78 ms: the reported
    /// case, where a night of 82 ms was read as "HRV is down".
    private var recalibratedDays: [DailyMetric] {
        let old = (1...20).map { day(String(format: "2026-09-%02d", $0), restingHr: 50, avgHrv: 90 + Double($0 % 3)) }
        let new = (1...6).map { day(String(format: "2026-10-%02d", $0), restingHr: 50,
                                    avgHrv: [77, 79, 78, 76, 80, 78][$0 - 1]) }
        return old + new + [day("2026-10-07", restingHr: 50, avgHrv: 82)]
    }

    private let cut = StressMath.Cut(hrvFirstNight: "2026-10-01", rhrFirstNight: "2026-10-01")

    func testANightAfterARecalibrationIsReadAgainstTheNightsAfterIt() throws {
        let days = recalibratedDays
        let ref = StressMath.reference(before: days.count - 1, in: days, cut: cut)
        XCTAssertEqual(try XCTUnwrap(ref.meanHRV), 78, accuracy: 1e-9)
        let model = try XCTUnwrap(StressModel(days: days, stored: [], cut: cut))
        XCTAssertGreaterThan(try XCTUnwrap(model.hrvDelta), 0, "82 ms is above the recalibrated 78 ms")
        let uncut = try XCTUnwrap(StressModel(days: days, stored: [], cut: .none))
        XCTAssertLessThan(try XCTUnwrap(uncut.hrvDelta), 0, "the old window read it as down")
    }

    func testADayBeforeTheRecalibrationKeepsItsOwnPast() {
        let days = recalibratedDays
        let index = days.firstIndex { $0.day == "2026-09-20" }!
        XCTAssertEqual(StressMath.reference(before: index, in: days, cut: cut),
                       StressMath.reference(before: index, in: days, cut: .none))
    }

    func testTheRepairReplacesOnlyNoopsOwnStaleRows() {
        let days = recalibratedDays
        let legacy = Dictionary(IntelligenceEngine.stressProxyRows(days: days, cut: .none).map { ($0.day, $0.value) },
                                uniquingKeysWith: { _, b in b })
        var existing = legacy
        existing["2026-10-03"] = 0.4   // an imported WHOOP value
        let repair = IntelligenceEngine.stressProxyRepairs(days: days, cut: cut, existing: existing,
                                                           importedDays: ["2026-10-03"])
        let fixed = Dictionary(repair.upserts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, b in b })
        let fresh = Dictionary(IntelligenceEngine.stressProxyRows(days: days, cut: cut).map { ($0.day, $0.value) },
                               uniquingKeysWith: { _, b in b })
        XCTAssertEqual(fixed["2026-10-07"] ?? -1, fresh["2026-10-07"] ?? -2, accuracy: 1e-9)
        XCTAssertNil(fixed["2026-10-03"], "an imported row is never replaced")
        XCTAssertFalse(repair.upserts.contains { $0.day < "2026-10-01" }, "days before the cut are untouched")
        // The first counted night has no counted night before it, so its stale row goes instead of staying.
        XCTAssertEqual(repair.deletions, ["2026-10-01"])
        // Applying the repair leaves nothing more to do.
        var applied = existing
        for row in repair.upserts { applied[row.day] = row.value }
        for gone in repair.deletions { applied[gone] = nil }
        let again = IntelligenceEngine.stressProxyRepairs(days: days, cut: cut, existing: applied,
                                                          importedDays: ["2026-10-03"])
        XCTAssertTrue(again.upserts.isEmpty)
        XCTAssertTrue(again.deletions.isEmpty)
    }

    func testTheRepairNeedsHistoryReachingTheCut() {
        let days = recalibratedDays.filter { $0.day >= "2026-10-02" }
        let repair = IntelligenceEngine.stressProxyRepairs(days: days, cut: cut, existing: [:], importedDays: [])
        XCTAssertTrue(repair.upserts.isEmpty)
        XCTAssertTrue(repair.deletions.isEmpty)
        XCTAssertTrue(IntelligenceEngine.stressProxyRepairs(days: recalibratedDays, cut: .none,
                                                            existing: [:], importedDays: []).upserts.isEmpty)
    }
}
