import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins which sessions the experimental training-based VO₂max reads on Training Load: on foot, with a
/// measured heart-rate trace, each bout once.
final class ExerciseVO2maxReadingTests: XCTestCase {
    private func session(_ id: String, day: Int, sport: String = "Running", km: Double = 12,
                         minutes: Double = 60, avgHr: Int = 150) -> UnifiedTrainingSession {
        let start = 1_757_937_600 - day * 86_400
        let row = WorkoutRow(startTs: start, endTs: start + Int(minutes * 60), sport: sport, source: "apple-health",
                             durationS: minutes * 60, energyKcal: nil, avgHr: avgHr, maxHr: nil, strain: nil,
                             distanceM: km * 1000, zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(id: id, kind: .endurance, row: row,
                                      components: [TrainingSessionComponent(id: id, row: row, metadata: nil)],
                                      fusionOrigin: "automatic")
    }

    private func measured(_ ids: [String]) -> TrainingCardioLoadResolution {
        var resolution = TrainingCardioLoadResolution()
        for id in ids {
            resolution.loads[id] = TrainingCardioLoad(sessionId: id, trimp: 100, effort: 50, source: .noopBand,
                                                      coveredMinutes: 60, possibleMinutes: 60)
        }
        return resolution
    }

    func testOnlyMeasuredSessionsOnFootAreRead() {
        let sessions = [session("measured", day: 2), session("average-only", day: 4),
                        session("ride", day: 6, sport: "Cycling"), session("twin", day: 2)]
        var resolution = measured(["measured", "ride", "twin"])
        resolution.duplicateSessionIds = ["twin"]
        let reading = TrainingLoadModel.exerciseVO2max(sessions: sessions, resolution: resolution,
                                                       restingByDay: [:], maxHR: 190, apple: [], offset: 0)
        XCTAssertEqual(reading.sessionsOnFoot, 2, "the ride is not on foot and the twin is the same bout")
        XCTAssertEqual(reading.sessionsUsed, 1, "a session with only an average heart rate is not a trace")
        XCTAssertEqual(reading.weekly.count, 1)
        XCTAssertFalse(reading.report.passes)
    }
}
