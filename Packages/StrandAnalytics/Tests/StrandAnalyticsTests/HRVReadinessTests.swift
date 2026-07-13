import XCTest
@testable import StrandAnalytics

/// HRVReadiness (Plews/Altini SWC) — the OPT-IN experimental HRV-readiness tier readout. The oracle for the
/// Android HRVReadinessTest; keep the two in lockstep (same fixtures, same assertions). Pins each tier on a
/// fixture series and the < minNights calibrating/nil edge (including that physiologically implausible
/// nights are dropped BEFORE the gate). Read-only variant: it feeds no downstream gate, so there is nothing
/// else to assert.
final class HRVReadinessTests: XCTestCase {

    // A high-then-primed history: 53 nights at 50 ms, the last 7 at 75 ms — the 7-night baseline sits
    // well above the personal normal band, so the tier reads .primed.
    private let primedHistory: [Double?] =
        Array(repeating: 50.0, count: 53) + Array(repeating: 75.0, count: 7)

    // The mirror: 53 nights at 50 ms, the last 7 at 38 ms — the 7-night baseline sits below the band, .suppressed.
    private let suppressedHistory: [Double?] =
        Array(repeating: 50.0, count: 53) + Array(repeating: 38.0, count: 7)

    // A perfectly flat history: baseline7 == longMean exactly, so the band collapses to the mean → .normal.
    private let flatHistory: [Double?] = Array(repeating: 60.0, count: 60)

    // MARK: - Tier

    func testPrimedFixtureTier() {
        let r = HRVReadiness.evaluate(avgHrv: primedHistory)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.tier, .primed)
        // The 7-night baseline is the last-7 mean, exp back to ms: exp(ln 75) = 75.
        XCTAssertEqual(r!.baseline7Ms, 75.0, accuracy: 1e-6)
        // Baseline above the long mean → the overreaching (falling-CV-while-below-mean) watch cannot fire.
        XCTAssertFalse(r!.overreachingWatch)
    }

    func testSuppressedFixtureTier() {
        let r = HRVReadiness.evaluate(avgHrv: suppressedHistory)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.tier, .suppressed)
        XCTAssertEqual(r!.baseline7Ms, 38.0, accuracy: 1e-6)
    }

    func testFlatHistoryIsNormalAndBandCollapsesToMean() {
        let r = HRVReadiness.evaluate(avgHrv: flatHistory)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.tier, .normal)
        // baseline7 == longMean and longSD == 0 → the band collapses to the mean, all reading back to 60 ms.
        XCTAssertEqual(r!.baseline7Ms, 60.0, accuracy: 1e-6)
        XCTAssertEqual(r!.normalLowMs, 60.0, accuracy: 1e-6)
        XCTAssertEqual(r!.normalHighMs, 60.0, accuracy: 1e-6)
    }

    // MARK: - Calibrating / nil edge (< minNights valid nights)

    func testBelowMinNightsIsNil() {
        // 13 valid nights is one short of the gate → nil (honest calibrating, never fabricated).
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: Array(repeating: 60.0, count: HRVReadiness.minNights - 1)))
        // Exactly minNights valid nights → a reading appears.
        XCTAssertNotNil(HRVReadiness.evaluate(avgHrv: Array(repeating: 60.0, count: HRVReadiness.minNights)))
    }

    func testOutOfRangeNightsAreDroppedBeforeGate() {
        // 13 in-range + 5 implausible (300 ms > hrvCfg.maxVal) → only 13 valid → still calibrating (nil).
        let mixed: [Double?] = Array(repeating: 60.0, count: 13) + Array(repeating: 300.0, count: 5)
        XCTAssertNil(HRVReadiness.evaluate(avgHrv: mixed))
        // Add one more in-range night → 14 valid → a reading appears (the implausible nights never count).
        let ok: [Double?] = Array(repeating: 60.0, count: 14) + Array(repeating: 300.0, count: 5)
        XCTAssertNotNil(HRVReadiness.evaluate(avgHrv: ok))
    }
}
