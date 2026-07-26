import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins T3.5 of Etappe T: `get_readiness` gains an optional cycle-phase line, gated on the SAME
/// opt-in (`AppModel.cycleAwarenessKey`) and built from the SAME z-scored nightly inputs
/// `AppModel.computeCyclePhase()` uses (`AICoachEngine.cyclePhaseNights`, duplicated on purpose since
/// the coach engine holds no `AppModel` reference), so the two can never disagree — and never surfaced
/// unless the engine actually detected a phase (never `.learning`/`.unknown`).
@MainActor
final class CoachCyclePhaseReadinessTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppModel.cycleAwarenessKey)
        super.tearDown()
    }

    private func makeEngine(days: [DailyMetric]) -> AICoachEngine {
        let repo = Repository(deviceId: "test-cycle-phase-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    private func day(_ dayStr: String) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90,
                    lightMin: 250, disturbances: 0, restingHr: 55, avgHrv: 60, recovery: 60,
                    strain: 10, exerciseCount: nil)
    }

    // MARK: - cyclePhaseNights (pure)

    func testCyclePhaseNightsEmptyForNoDays() {
        let (nights, usable) = AICoachEngine.cyclePhaseNights(days: [])
        XCTAssertTrue(nights.isEmpty)
        XCTAssertFalse(usable)
    }

    func testCyclePhaseNightsSortsOldestToNewestRegardlessOfInputOrder() {
        let days = [day("2026-01-02"), day("2026-01-01")]
        let (nights, _) = AICoachEngine.cyclePhaseNights(days: days)
        XCTAssertEqual(nights.map(\.day), ["2026-01-01", "2026-01-02"])
    }

    // MARK: - readinessBlock gate

    func testReadinessBlockOmitsCyclePhaseWhenOptInIsOff() {
        UserDefaults.standard.set(false, forKey: AppModel.cycleAwarenessKey)
        let engine = makeEngine(days: [day("2026-01-01")])
        XCTAssertFalse(engine.readinessBlock().contains("Cycle phase"))
    }

    /// Opted in but with far too little history to classify — must stay silent (`.learning`), never a
    /// fabricated phase.
    func testReadinessBlockOmitsCyclePhaseWhenStillLearning() {
        UserDefaults.standard.set(true, forKey: AppModel.cycleAwarenessKey)
        let engine = makeEngine(days: [day("2026-01-01")])
        XCTAssertFalse(engine.readinessBlock().contains("Cycle phase"))
    }
}
