import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The cycle page on Android: the fertile-days estimate and the training pattern come from the shared math.
@MainActor
final class CoreCycleTests: XCTestCase {
    func testFertileEstimateAndStatusFollowFertileWindow() {
        // Three past rises on days 14 to 16: ovulation 13 to 15, window day 8 to 15.
        let before = CoreCycle.fertile(pastRiseDays: [14, 15, 16], currentRiseDay: nil, positiveTestDay: nil, cycleDay: 5)
        XCTAssertEqual(before?.firstDay, 8)
        XCTAssertEqual(before?.lastDay, 15)
        XCTAssertEqual(before?.basis, "history")
        XCTAssertEqual(before?.status, "before")
        XCTAssertEqual(before?.daysUntil, 3)
        let during = CoreCycle.fertile(pastRiseDays: [14, 15, 16], currentRiseDay: nil, positiveTestDay: nil, cycleDay: 10)
        XCTAssertEqual(during?.status, "during")
        XCTAssertEqual(during?.day, 3)
        XCTAssertEqual(during?.of, 8)
        let test = CoreCycle.fertile(pastRiseDays: [], currentRiseDay: nil, positiveTestDay: 12, cycleDay: 12)
        XCTAssertEqual(test?.basis, "ovulationTest")
        XCTAssertEqual(test?.lastDay, 13)
        XCTAssertEqual(CoreCycle.fertile(pastRiseDays: [], currentRiseDay: 15, positiveTestDay: nil, cycleDay: 18)?.status, "over")
        XCTAssertNil(CoreCycle.fertile(pastRiseDays: [14, 15], currentRiseDay: nil, positiveTestDay: nil, cycleDay: 3))
    }

    func testPatternWithoutSessionsIsStillLearning() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let cycles = [CycleTrainingPattern.Cycle(start: "2026-09-01", shift: "2026-09-15")]
        let out = await CoreCycle.pattern(reader: reader, cycles: cycles, dismissed: [])
        XCTAssertEqual(out.cyclesUsed, 0)
        XCTAssertEqual(Set(out.verdicts.keys), ["period", "follicular", "luteal"])
        XCTAssertTrue(out.verdicts.values.allSatisfy { $0.kind == "learning" })
    }

    func testPatternVerdictReadsHarderLuteal() {
        // Four cycles with a shift; luteal sessions rated a point higher than follicular ones.
        let cycles = ["2026-05-01", "2026-05-29", "2026-06-26", "2026-07-24"].enumerated().map { i, start -> CycleTrainingPattern.Cycle in
            let shift = ["2026-05-15", "2026-06-12", "2026-07-10", "2026-08-07"][i]
            return CycleTrainingPattern.Cycle(start: start, shift: shift)
        }
        var sessions: [CycleTrainingPattern.Session] = []
        for (start, shift) in zip(["2026-05-08", "2026-06-05", "2026-07-03", "2026-07-31"],
                                  ["2026-05-20", "2026-06-17", "2026-07-15", "2026-08-12"]) {
            sessions.append(.init(day: start, rpe: 6))
            sessions.append(.init(day: shift, rpe: 7.2))
        }
        let out = CoreCycle.output(CycleTrainingPattern.analyse(sessions: sessions, cycles: cycles))
        XCTAssertEqual(out.verdicts["luteal"]?.kind, "harder")
        XCTAssertEqual(out.verdicts["luteal"]?.rpeDelta ?? 0, 1.2, accuracy: 1e-9)
    }
}
