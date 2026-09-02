import XCTest
@testable import StrandAnalytics

final class SleepDebtTests: XCTestCase {

    /// Three nights at need (8 h = 480 min) → zero balance, three counted nights.
    func testOnTargetNetsToZero() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480), ("2026-06-02", 480), ("2026-06-03", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 3)
        XCTAssertFalse(l.isDebt)
        XCTAssertEqual(l.needMin, 480.0, accuracy: 1e-9)
    }

    /// Debt carries forward as part of the following night's need; a night that meets
    /// that complete need clears it instead of producing a positive surplus.
    func testDebtRecursAndMeetingNeedClearsIt() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 360),   // −120
            ("2026-06-02", 546),   // base 480 + prior debt 66
            ("2026-06-03", 540),   // raw bar remains +60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertFalse(l.isDebt)
        XCTAssertEqual(l.nights.map { $0.deltaMin }, [-120, 66, 60])
    }

    /// Nights with no usable sleep are skipped entirely (never zero-filled as debt).
    func testSkipsNoDataNights() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480),
            ("2026-06-02", nil),     // skipped
            ("2026-06-03", 0),       // skipped (non-positive)
            ("2026-06-04", 420),     // −60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nightCount, 2)
        XCTAssertEqual(l.balanceMin, -33.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.day }, ["2026-06-01", "2026-06-04"])
    }

    /// Only the most-recent `window` COUNTED nights are in scope.
    func testWindowCapKeepsMostRecent() {
        // 16 nights, each 60 min UNDER base need. The recurrence is computed only
        // across the retained 14 counted nights, preserving the existing window.
        let series: [(day: String, totalSleepMin: Double?)] = (1...16).map {
            (String(format: "2026-06-%02d", $0), Double(420))
        }
        let l = SleepDebt.ledger(series: series, needHours: 8.0, window: 14)
        XCTAssertEqual(l.nightCount, 14)               // capped
        XCTAssertEqual(l.balanceMin, -73.3, accuracy: 1e-9)
        XCTAssertEqual(l.nights.first?.day, "2026-06-03")      // oldest kept
        XCTAssertEqual(l.nights.last?.day, "2026-06-16")       // newest kept
    }

    /// Empty / all-skipped input → empty ledger, zero balance.
    func testEmptyLedger() {
        let l = SleepDebt.ledger(series: [], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 0)
        XCTAssertTrue(l.nights.isEmpty)

        let allNil: [(day: String, totalSleepMin: Double?)] = [("2026-06-01", nil)]
        XCTAssertEqual(SleepDebt.ledger(series: allNil).nightCount, 0)
    }

    /// The default need is AnalyticsEngine.Rest.defaultNeedHours (8 h).
    func testDefaultNeedIsEightHours() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 420)])
        XCTAssertEqual(l.needMin, AnalyticsEngine.Rest.defaultNeedHours * 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.balanceMin, -33.0, accuracy: 1e-9)
    }

    /// Main sleep remains the canonical nightly figure, while a separately-recorded nap
    /// contributes its asleep minutes when the caller prepares the debt series.
    func testNapMinutesAddDebtRepaymentCredit() throws {
        let credited = try XCTUnwrap(SleepDebt.creditedSleepMin(mainSleepMin: 392, napSleepMin: 48))
        XCTAssertEqual(credited, 440, accuracy: 1e-9)
        let l = SleepDebt.ledger(series: [("2026-06-01", credited)], needHours: 8.0)
        XCTAssertEqual(l.balanceMin, -22, accuracy: 1e-9)
    }

    func testNapCreditRequiresMainSleepAndIgnoresNegativeNapMinutes() {
        XCTAssertNil(SleepDebt.creditedSleepMin(mainSleepMin: nil, napSleepMin: 48))
        XCTAssertNil(SleepDebt.creditedSleepMin(mainSleepMin: 0, napSleepMin: 48))
        XCTAssertEqual(SleepDebt.creditedSleepMin(mainSleepMin: 392, napSleepMin: -10), 392.0)
    }

    func testDebtBelowTenMinutesClearsButExactlyTenRemains() {
        XCTAssertEqual(SleepDebt.onTargetBandMin, 10, accuracy: 1e-9)
        // 18 min shortfall × 0.55 = 9.9 min -> cleared.
        XCTAssertEqual(
            SleepDebt.ledger(series: [("2026-06-01", 462)], needHours: 8).balanceMin,
            0,
            accuracy: 1e-9)
        // A deliberately exact 10 min calculated debt remains debt.
        let slept = 480.0 - (10.0 / 0.55)
        XCTAssertEqual(
            SleepDebt.ledger(series: [("2026-06-01", slept)], needHours: 8).balanceMin,
            -10,
            accuracy: 1e-9)
    }

    func testSurplusNeverCreatesPositiveBalanceAndRawBarsStayUnchanged() {
        let l = SleepDebt.ledger(series: [
            ("2026-06-01", 600),
            ("2026-06-02", 420),
        ], needHours: 8)
        XCTAssertEqual(l.balanceMin, -33, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map(\.deltaMin), [120, -60])
    }

    func testImportedDebtIsVerbatimButDoesNotSeedFollowingFallback() {
        let values = SleepDebt.debtSeries(
            series: [("2026-06-01", 420), ("2026-06-02", 480)],
            needHours: 8,
            importedDebtMin: ["2026-06-01": 61.25])
        XCTAssertEqual(values[0].value, 61.25, accuracy: 1e-9)
        XCTAssertEqual(values[1].value, 18.2, accuracy: 1e-9)
    }

    func testDebtSeriesRoundsLocalOutputsToLedgerPrecision() {
        let input: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 420), ("2026-06-02", 410),
        ]
        let values = SleepDebt.debtSeries(series: input, needHours: 8)
        let ledger = SleepDebt.ledger(series: input, needHours: 8)
        XCTAssertEqual(values.last?.value ?? -1, 56.7, accuracy: 1e-9)
        XCTAssertEqual(values.last?.value ?? -1, ledger.magnitudeMin, accuracy: 1e-9)
    }

    func testImportedOnlyGapDoesNotConsumeOneOfFourteenUsableNights() {
        let usable: [(day: String, totalSleepMin: Double?)] = (1...14).map {
            (String(format: "2026-06-%02d", $0), 420)
        }
        let input = Array(usable.prefix(13))
            + [(day: "2026-06-14-imported-only", totalSleepMin: nil)]
            + Array(usable.suffix(1))
        let values = SleepDebt.debtSeries(
            series: input,
            needHours: 8,
            importedDebtMin: ["2026-06-14-imported-only": 91.25])

        XCTAssertEqual(values.count, 15)
        XCTAssertEqual(values[13].value, 91.25, accuracy: 1e-9)
        XCTAssertEqual(values.last?.value ?? -1,
                       SleepDebt.ledger(series: usable, needHours: 8, window: 14).magnitudeMin,
                       accuracy: 1e-9)
    }

    func testDebtSeriesKeepsFullHistoryWithPerDayTrailingLedgerParity() {
        let input: [(day: String, totalSleepMin: Double?)] = (1...16).map {
            (String(format: "2026-06-%02d", $0), 390 + Double($0))
        }
        let values = SleepDebt.debtSeries(series: input, needHours: 8, window: 14)

        XCTAssertEqual(values.count, 16)
        for index in values.indices {
            let expected = SleepDebt.ledger(
                series: Array(input.prefix(index + 1)), needHours: 8, window: 14).magnitudeMin
            XCTAssertEqual(values[index].day, input[index].day)
            XCTAssertEqual(values[index].value, expected, accuracy: 1e-9,
                           "per-day parity at \(values[index].day)")
        }
    }

    /// round1 is exercised on the directly-constructed value too, so the rounding mode is
    /// pinned independent of the (slept − need) arithmetic path, both signs + a non-tie.
    func testRound1HalfTiesAwayFromZero() {
        XCTAssertEqual(SleepDebt.round1(-0.05), -0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(0.05), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.04), 0.0, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.25), -0.3, accuracy: 1e-9)
    }
}
