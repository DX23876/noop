import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins that the chat context quotes the VO₂max the screens show (`CardioEvidence.display`): NOOP's stored
/// weekly estimate as the headline and Apple Watch's latest reading with its date — whether or not a waist
/// measurement exists. The context used to recompute Nes 2011 itself, which needs a waist, so a wearer
/// without one saw the Uth estimate on every screen while the coach was told nothing.
@MainActor
final class CoachContextVO2maxTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "profile.waistCm")
        super.tearDown()
    }

    private func makeEngine() -> AICoachEngine {
        let repo = Repository(deviceId: "test-vo2max-\(UUID().uuidString)")
        repo.days = (1...7).map {
            DailyMetric(day: "2026-01-0\($0)", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil)
        }
        return AICoachEngine(repo: repo)
    }

    private func display(appleDay: String?) -> VO2maxDisplay {
        let estimates = [VO2maxReading(day: "2026-01-06", value: 52, segment: "vo2max_est")]
        let apple = appleDay.map { [VO2maxReading(day: $0, value: 41.2, segment: Repository.appleHealthSource)] } ?? []
        return CardioEvidence.display(estimates: estimates, apple: apple, through: "2026-01-07")
    }

    func testTheContextQuotesTheEstimateWithoutAWaistMeasurement() {
        ProfileStore().waistCm = 0
        let engine = makeEngine()
        engine.vo2maxDisplay = display(appleDay: nil)
        let context = engine.buildContext()
        XCTAssertTrue(context.contains("VO2max: 52.0 ml/kg/min (NOOP weekly estimate, not a lab test)"))
        XCTAssertFalse(context.contains("Apple Watch VO2max"))
    }

    func testAnOlderAppleReadingKeepsItsDate() {
        let engine = makeEngine()
        engine.vo2maxDisplay = display(appleDay: "2025-11-20")
        XCTAssertTrue(engine.buildContext().contains("Apple Watch VO2max last measured 41.2 ml/kg/min on 2025-11-20"))
    }

    func testNoReadingMeansNoVO2maxLine() {
        let engine = makeEngine()
        engine.vo2maxDisplay = nil
        XCTAssertFalse(engine.buildContext().contains("VO2max: "))
    }
}
