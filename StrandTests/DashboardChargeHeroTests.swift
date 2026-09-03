import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the Charge hero rule the two DASHBOARDS now share with the two Today screens.
///
/// Reported from a real device: with the Trends dashboard chosen as Today, CHARGE read "—" all morning
/// while REST showed a number right beside it. Both dashboards drew `displayDay?.recovery` raw, which is
/// nil on every day before tonight's night is scored — including the whole stretch after the 04:00
/// rollover. That is the #543 regression `LiquidChargeCarryTests` already closed for Liquid, reappearing
/// on the two newest screens: the same shortest-possible-wrong-version-of-a-Today-rule shape as the
/// banked-estimate and per-field-vitals bugs before it.
///
/// `LiquidChargeCarryTests` pins the presentation truth table (`resolve(todayRecovery:priorScored:…)`).
/// This pins the COMPOSITION above it — `ChargeDisplay.resolve(days:displayDay:selectedDayKey:isToday:)`,
/// the one call a dashboard makes — and that it orders the three steps exactly the way Liquid's load()
/// does. Pure: no strap, no clock, no view.
@MainActor
final class DashboardChargeHeroTests: XCTestCase {

    // MARK: - Fixtures

    /// Day keys anchored on the real today, so a stray persisted recalibration epoch (which drops nights
    /// dated before it) can never silently starve the baseline this test needs to be established.
    private func key(daysAgo: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Repository.localDayKey(d)
    }

    private func day(_ key: String, hrv: Double?, recovery: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                    recovery: recovery, strain: nil, exerciseCount: nil)
    }

    /// A wearer well past the seed gate: eight scored nights, then an unscored today. Oldest→newest,
    /// the order `repo.days` is in.
    private func establishedHistory(todayRecovery: Double?) -> (days: [DailyMetric], today: DailyMetric) {
        var days = (1...8).reversed().map { n in
            day(key(daysAgo: n), hrv: 52 + Double(n % 3), recovery: 70 + Double(n))
        }
        let today = day(key(daysAgo: 0), hrv: todayRecovery == nil ? nil : 55, recovery: todayRecovery)
        days.append(today)
        return (days, today)
    }

    // MARK: - THE regression

    /// The reported case: an established wearer, today not scored yet. The hero must draw the prior
    /// night's REAL number, stamped with whose night it is — not "—".
    func testUnscoredTodayCarriesTheLastScoredNight() {
        let h = establishedHistory(todayRecovery: nil)
        let display = ChargeDisplay.resolve(days: h.days, displayDay: h.today,
                                            selectedDayKey: h.today.day, isToday: true)
        guard case .carried(let pct, let caption) = display else {
            return XCTFail("an unscored today with a scored history must carry, got \(display)")
        }
        XCTAssertEqual(pct, 71, "the carried value is the freshest scored row's REAL recovery (yesterday's)")
        XCTAssertTrue(caption.hasPrefix("Last night"),
                      "a fresh carry must be stamped as last night's, never passed off as today's: \(caption)")
    }

    /// Today's own score always wins — the carry may never displace a scored day.
    func testScoredTodayShowsItsOwnScore() {
        let h = establishedHistory(todayRecovery: 64)
        let display = ChargeDisplay.resolve(days: h.days, displayDay: h.today,
                                            selectedDayKey: h.today.day, isToday: true)
        XCTAssertEqual(display, .scored(pct: 64))
    }

    // MARK: - The gates that keep a dashboard from over-claiming

    /// A NAVIGATED past day is missing data, not mid-calibration and not a carry target: carrying into the
    /// past would print a night recorded AFTER the day being read. Same gate `TodayView.recoveryCalibration`
    /// and `lastScoredRecoveryDay` apply at offset 0.
    func testPastDayNeitherCarriesNorCalibrates() {
        let h = establishedHistory(todayRecovery: nil)
        let past = day(key(daysAgo: 3), hrv: nil, recovery: nil)
        let display = ChargeDisplay.resolve(days: h.days, displayDay: past,
                                            selectedDayKey: past.day, isToday: false)
        XCTAssertEqual(display, .noData,
                       "a past day shows its own row or nothing — it must never borrow a later night")
    }

    /// Cold start: no banked nights at all. The honest answer is the calibrating countdown, not a dash —
    /// and calibration outranks any carry, because mid-calibration there is no trustworthy prior score.
    func testColdStartCalibratesRatherThanBlanking() {
        let display = ChargeDisplay.resolve(days: [], displayDay: nil,
                                            selectedDayKey: Repository.logicalDayKey(Date()), isToday: true)
        XCTAssertEqual(display, .calibrating(nights: 0),
                       "a brand-new wearer reads 'Calibrating, 0 of 4', not 'No data'")
    }

    // MARK: - What the ring draws for each state

    /// A carried state MUST hand the ring its provenance line and MUST NOT hand it the calibrating
    /// countdown; the two are mutually exclusive by construction, and a carry without its stamp is the one
    /// thing the carry is not allowed to be.
    func testCarriedStateExposesItsStampAndNoCountdown() {
        let h = establishedHistory(todayRecovery: nil)
        let display = ChargeDisplay.resolve(days: h.days, displayDay: h.today,
                                            selectedDayKey: h.today.day, isToday: true)
        XCTAssertNotNil(display.carriedCaption, "a carried number must always say whose night it is")
        XCTAssertNil(display.emptyRingLines, "a carried state draws a number, so it has no empty-ring copy")
        XCTAssertNotNil(display.pct, "the dashboards' rings key on pct — a carry must supply one")
    }

    /// The calibrating state owns the ring's interior: the word plus its "N of 4" count, the same two
    /// lines classic Today's `ringEmptyOverlay` draws. It carries no provenance stamp, because there is
    /// no borrowed night behind it.
    func testCalibratingStateExposesTheCountdownAndNoStamp() {
        let display = ChargeDisplay.resolve(days: [], displayDay: nil,
                                            selectedDayKey: Repository.logicalDayKey(Date()), isToday: true)
        guard let lines = display.emptyRingLines else {
            return XCTFail("a calibrating ring must say what it is doing instead of drawing a dash")
        }
        XCTAssertEqual(lines.subtitle, "0 of \(Baselines.minNightsSeed)")
        XCTAssertNil(display.carriedCaption, "nothing was carried, so there is nothing to stamp")
        XCTAssertNil(display.pct, "'calibrating' is not a score — the ring must draw no number")
    }

    /// A scored day and a no-data day both leave the ring's extra copy empty: one draws its number, the
    /// other honestly draws the dash.
    func testScoredAndNoDataCarryNoExtraCopy() {
        let scored = ChargeDisplay.scored(pct: 64)
        XCTAssertNil(scored.carriedCaption)
        XCTAssertNil(scored.emptyRingLines)
        XCTAssertNil(ChargeDisplay.noData.carriedCaption)
        XCTAssertNil(ChargeDisplay.noData.emptyRingLines,
                     "no data has nothing to say beyond the dash — inventing copy here would over-claim")
    }

    // MARK: - Parity with the three-step form Liquid uses

    /// The composition is the whole point of the one-call form: a dashboard that ordered calibration and
    /// carry differently would disagree with Today about the same data. This runs Liquid's load() steps by
    /// hand and asserts the one call lands in the same place, across all three today-states.
    func testOneCallCompositionMatchesLiquidsThreeSteps() {
        for todayRecovery in [nil, 64] as [Double?] {
            for history in [establishedHistory(todayRecovery: todayRecovery).days, []] {
                let displayDay = history.last
                let tkey = displayDay?.day ?? Repository.logicalDayKey(Date())
                // Liquid's load(), verbatim.
                let calNights = RecoveryScorer.calibrationNights(nightlyHrv: history.map(\.avgHrv),
                                                                 dayKeys: history.map(\.day),
                                                                 hasRecovery: displayDay?.recovery != nil)
                let priorScored = TodayView.lastScoredRecoveryDay(days: history, selectedDayKey: tkey,
                                                                  isToday: true,
                                                                  todayScored: displayDay?.recovery != nil,
                                                                  isCalibrating: calNights != nil)
                let expected = ChargeDisplay.resolve(todayRecovery: displayDay?.recovery,
                                                     priorScored: priorScored,
                                                     calibrationNights: calNights, todayKey: tkey)
                let actual = ChargeDisplay.resolve(days: history, displayDay: displayDay,
                                                   selectedDayKey: tkey, isToday: true)
                XCTAssertEqual(actual, expected,
                               "the dashboards' one-call form must compose exactly as Liquid's load() does")
            }
        }
    }
}
