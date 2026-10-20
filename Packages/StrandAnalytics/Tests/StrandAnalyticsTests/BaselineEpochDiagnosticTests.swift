import XCTest
@testable import StrandAnalytics

/// #731: the epoch-drop diagnostic must report exactly what the epoch-aware fold drops, so a "Charge is
/// stuck" strap log explains itself. Pinned against `foldHistory`'s own behaviour, not just in isolation.
final class BaselineEpochDiagnosticTests: XCTestCase {

    /// 2026-07-19 00:00:00 UTC — the recalibration instant used throughout.
    private let epoch: Double = 1_784_419_200

    private let days = ["2026-07-16", "2026-07-17", "2026-07-18",   // before the epoch → dropped
                        "2026-07-19", "2026-07-20", "2026-07-21"]   // on/after → kept

    func testNoEpochDropsNothing() {
        let d = Baselines.epochDropDiagnostic(dayKeys: days, baselineEpoch: 0)
        XCTAssertEqual(d.dropped, 0)
        XCTAssertNil(d.epochDay, "no recalibration → no epoch day to report")
    }

    func testDropsOnlyNightsStrictlyBeforeTheEpoch() {
        let d = Baselines.epochDropDiagnostic(dayKeys: days, baselineEpoch: epoch)
        XCTAssertEqual(d.dropped, 3, "16/17/18 precede the epoch; the epoch day itself is KEPT")
        XCTAssertEqual(d.epochDay, "2026-07-19")
    }

    /// The diagnostic is only useful if it agrees with the fold it describes: dropped + used == total.
    func testAgreesWithFoldHistory() {
        let cfg = Baselines.metricCfg["hrv"]!
        let values: [Double?] = [40, 41, 42, 43, 44, 45]   // all in-range, so every KEPT night is valid
        let state = Baselines.foldHistory(values, dayKeys: days, cfg: cfg, baselineEpoch: epoch)
        let d = Baselines.epochDropDiagnostic(dayKeys: days, baselineEpoch: epoch)
        XCTAssertEqual(d.dropped + state.nValid, days.count,
                       "every night is either dropped by the epoch or counted by the fold")
        XCTAssertEqual(state.nValid, 3, "the reporter's exact signature: 6 nights on file, 3 usable")
    }

    /// The reporter's case (#731): plenty of valid history, but a recent recalibration leaves the
    /// baseline one night short of `minNightsSeed` — which read as "stuck" with no explanation.
    func testReproducesTheStuckAtThreeSignature() {
        let cfg = Baselines.metricCfg["hrv"]!
        // 15 nights of good HRV, recalibrated so only the last 3 survive.
        let allDays = (8...22).map { String(format: "2026-07-%02d", $0) }
        let values: [Double?] = Array(repeating: 45.0, count: allDays.count)
        let state = Baselines.foldHistory(values, dayKeys: allDays, cfg: cfg, baselineEpoch: 1_784_505_600) // 07-20
        let d = Baselines.epochDropDiagnostic(dayKeys: allDays, baselineEpoch: 1_784_505_600)
        XCTAssertEqual(d.dropped, 12)
        XCTAssertEqual(state.nValid, 3)
        XCTAssertFalse(state.usable, "3 < minNightsSeed(4) → Charge stays nil, exactly as reported")
    }

    /// `firstNightAfterRecalibration` is the fold's own cut written as a day key: every night the fold
    /// drops sorts below it, every night it keeps sorts at or above it.
    func testFirstNightAfterRecalibrationMatchesTheFoldsCut() {
        XCTAssertNil(Baselines.firstNightAfterRecalibration(epoch: 0))
        let keys = (1...9).map { String(format: "2026-10-%02d", $0) }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        for stamp in ["2026-10-04 10:30", "2026-10-04 00:00", "2026-10-04 23:59"] {
            let epoch = fmt.date(from: stamp)!.timeIntervalSince1970
            let first = Baselines.firstNightAfterRecalibration(epoch: epoch)!
            let dropped = Baselines.epochDropDiagnostic(dayKeys: keys, baselineEpoch: epoch).dropped
            XCTAssertEqual(keys.filter { $0 < first }.count, dropped, stamp)
        }
        XCTAssertEqual(Baselines.firstNightAfterRecalibration(
            epoch: fmt.date(from: "2026-10-04 10:30")!.timeIntervalSince1970), "2026-10-05")
        XCTAssertEqual(Baselines.firstNightAfterRecalibration(
            epoch: fmt.date(from: "2026-10-04 00:00")!.timeIntervalSince1970), "2026-10-04")
    }
}
