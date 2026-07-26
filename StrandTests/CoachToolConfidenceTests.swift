import XCTest
import WhoopStore
@testable import Strand

/// Pins T2 of Etappe T: `chargeConfidenceLine()` (`AICoach.swift`) travels with the tool-path OUTPUT
/// it qualifies (`get_biometric_summary` / `get_charge_drivers` in `CoachTools.runCoachTool`), not just
/// the non-tool `buildFullContext()` path, which already appended it before this change. The regression
/// this guards against: the tool path used `toolModeContext` (a short note + plan block, no numbers),
/// so a "calibrating" warning never reached a tool-fetched Charge number — and after the fix, that it
/// doesn't get appended TWICE anywhere.
@MainActor
final class CoachToolConfidenceTests: XCTestCase {

    private func makeEngine(days: [DailyMetric] = []) -> AICoachEngine {
        let repo = Repository(deviceId: "test-charge-confidence-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    /// A single day with `recovery` set but nothing else: `Baselines.foldHistory` can't call an HRV
    /// baseline "usable" off one data point, so `ScoreConfidence.charge` returns `.calibrating` —
    /// exactly the case the confidence line exists to flag.
    private func oneCalibratingDay() -> [DailyMetric] {
        let today = Repository.logicalDayKey(Date())
        return [DailyMetric(day: today, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                             lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: 45, recovery: 60,
                             strain: nil, exerciseCount: nil)]
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testEmptyDaysMeansNoConfidenceLine() {
        let engine = makeEngine()
        XCTAssertNil(engine.chargeConfidenceLine())
    }

    func testOneSeededDayIsCalibrating() {
        let engine = makeEngine(days: oneCalibratingDay())
        let line = engine.chargeConfidenceLine()
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("Charge confidence today:"))
        XCTAssertTrue(line!.contains("calibrating"))
        XCTAssertTrue(line!.contains("not a real score yet"))
    }

    func testBiometricSummaryToolAppendsConfidenceExactlyOnce() async {
        let engine = makeEngine(days: oneCalibratingDay())
        engine.dataConsent = true
        let result = await engine.runCoachTool("get_biometric_summary", input: [:])
        XCTAssertEqual(occurrences(of: "Charge confidence today:", in: result), 1)
    }

    func testChargeDriversToolAppendsConfidenceExactlyOnce() async {
        let engine = makeEngine(days: oneCalibratingDay())
        engine.dataConsent = true
        let result = await engine.runCoachTool("get_charge_drivers", input: [:])
        XCTAssertEqual(occurrences(of: "Charge confidence today:", in: result), 1)
    }

    /// Regression: `buildFullContext()` (the non-tool path) already appends this line on its own
    /// (`AICoach.swift`); T2 must not cause it to appear twice there.
    func testBuildFullContextStillAppendsConfidenceExactlyOnce() async {
        let engine = makeEngine(days: oneCalibratingDay())
        engine.dataConsent = true
        let result = await engine.buildFullContext()
        XCTAssertEqual(occurrences(of: "Charge confidence today:", in: result), 1)
    }
}
