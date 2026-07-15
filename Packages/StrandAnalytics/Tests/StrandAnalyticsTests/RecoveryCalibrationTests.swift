import XCTest
@testable import StrandAnalytics

/// Unit tests for `RecoveryScorer.calibrationNights`, the pure helper behind the Today recovery
/// cold-start "Calibrating — N of 4 nights" affordance. Recovery is nil until the HRV baseline
/// crosses the seed gate (Baselines.minNightsSeed valid nights); this surfaces honest progress
/// instead of a bare empty state. N is the HRV baseline's real `nValid` from folding the SAME
/// day-keyed, epoch-aware history the recovery engine folds. Mirrors the Android
/// RecoveryCalibrationTest case-for-case.
final class RecoveryCalibrationTests: XCTestCase {

    private let seed = Baselines.minNightsSeed // 4

    /// Consecutive "yyyy-MM-dd" keys (2026-01-01 …), parallel to a nightly-value array. The values
    /// drive the fold; the keys only matter once a recalibration epoch drops the pre-epoch tail.
    private func keys(_ count: Int) -> [String] {
        (0..<count).map { i in String(format: "2026-01-%02d", i + 1) }
    }

    /// The UTC day-start epoch (seconds) for a "yyyy-MM-dd" key, computed exactly as
    /// `Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)` does, so a test epoch lands on a real boundary.
    private func epoch(_ dayKey: String) -> Double {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: dayKey)!.timeIntervalSince1970
    }

    /// Call helper pinning `baselineEpoch: 0` (no recalibration) so the plain fold is deterministic
    /// regardless of any UserDefaults `hrvBaselineEpoch` set by another test in the process.
    private func nights(_ hrv: [Double?], hasRecovery: Bool) -> Int? {
        RecoveryScorer.calibrationNights(nightlyHrv: hrv, dayKeys: keys(hrv.count),
                                         hasRecovery: hasRecovery, baselineEpoch: 0)
    }

    func testNilWhenRecoveryAlreadyExists() {
        XCTAssertNil(nights([55.0, 60.0], hasRecovery: true))
    }

    func testZeroWhenNoNightHasHrvYet() {
        // Brand-new user (no valid HRV nights yet) → 0, so Charge reads "Calibrating — 0 of N"
        // rather than a bare "No data" (#335).
        XCTAssertEqual(nights([nil, nil], hasRecovery: false), 0)
    }

    func testCountsNightsCarryingHrvBelowSeed() {
        XCTAssertEqual(nights([55.0, nil, 61.0], hasRecovery: false), 2)
    }

    func testOneNightReportsOne() {
        XCTAssertEqual(nights([58.0], hasRecovery: false), 1)
    }

    func testNilAtOrAboveSeedDoesNotClaimCalibrating() {
        // At/above the seed gate the baseline should be usable; if recovery is still nil it's
        // some other gap, so we must NOT show a misleading "calibrating 4 of 4".
        let hrv: [Double?] = (1...seed).map { 55.0 + Double($0) }
        XCTAssertNil(nights(hrv, hasRecovery: false))
    }

    func testIgnoresNilHrvNights() {
        XCTAssertEqual(nights([55.0, nil, nil, 60.0], hasRecovery: false), 2)
    }

    func testIgnoresOutOfRangeHrvNights() {
        // A physiologically implausible avgHrv (outside the HRV config bounds 5...250) does not
        // advance the recovery seed in Baselines.update, so it must not be counted here either —
        // only the in-range night does. Keeps the displayed N in step with the real nValid.
        XCTAssertEqual(nights([55.0, 4.0, 999.0], hasRecovery: false), 1)
    }

    // MARK: - Bug B (#393 follow-up): recalibration must not strand a calibrating user on "Needs the strap"

    func testRecalibrationDropsPreEpochNightsSoNTracksTheRealBaseline() {
        // Six in-range nights, then a manual "Recalibrate HRV baseline" epoch dated at 2026-01-05:
        // the engine's fold DROPS the four pre-epoch nights, so the real nValid is the 2 post-epoch
        // nights — a genuinely-calibrating baseline. The old per-night bounds count was 6 (>= seed)
        // and returned nil, which stranded the score side on "Needs the strap". N must now read 2.
        let hrv: [Double?] = Array(repeating: 55.0, count: 6)
        let result = RecoveryScorer.calibrationNights(
            nightlyHrv: hrv, dayKeys: keys(6), hasRecovery: false, baselineEpoch: epoch("2026-01-05"))
        XCTAssertEqual(result, 2)
    }

    func testRecalibrationThatLeavesSeededBaselineStillReturnsNil() {
        // If enough post-epoch nights remain to cross the seed gate, the baseline is usable again and a
        // nil recovery is some OTHER gap — so we must not claim "calibrating" (mirrors the non-recalibrated
        // at/above-seed case). Epoch at 2026-01-02 drops one night; five post-epoch nights → nValid 5.
        let hrv: [Double?] = Array(repeating: 55.0, count: 6)
        let result = RecoveryScorer.calibrationNights(
            nightlyHrv: hrv, dayKeys: keys(6), hasRecovery: false, baselineEpoch: epoch("2026-01-02"))
        XCTAssertNil(result)
    }
}
