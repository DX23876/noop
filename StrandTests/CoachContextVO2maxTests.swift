import XCTest
import WhoopStore
@testable import Strand

/// Pins T3.1 of Etappe T: `buildContext()` (the chat context) now surfaces the same on-device VO2max
/// estimate `goalEvidence()` already computed for the Goal Feasibility screen (`estimatedVO2max`,
/// `AICoach.swift`) — previously computed there and never fed into the chat context at all.
@MainActor
final class CoachContextVO2maxTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "profile.waistCm")
        super.tearDown()
    }

    private func makeEngine(days: [DailyMetric]) -> AICoachEngine {
        let repo = Repository(deviceId: "test-vo2max-\(UUID().uuidString)")
        repo.days = days
        return AICoachEngine(repo: repo)
    }

    private func day(_ dayStr: String, restingHr: Int) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: restingHr, avgHrv: nil, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    private func sevenDays() -> [DailyMetric] {
        (1...7).map { day("2026-01-0\($0)", restingHr: 55) }
    }

    func testBuildContextIncludesVO2maxWhenAWaistMeasurementExists() {
        ProfileStore().waistCm = 85
        let engine = makeEngine(days: sevenDays())
        XCTAssertTrue(engine.buildContext().contains("Estimated VO2max:"))
    }

    func testBuildContextOmitsVO2maxWithoutAWaistMeasurement() {
        ProfileStore().waistCm = 0
        let engine = makeEngine(days: sevenDays())
        XCTAssertFalse(engine.buildContext().contains("Estimated VO2max:"))
    }
}
