import Foundation
import XCTest
import WhoopStore
@testable import NoopCore

final class GoalMeasurementsTests: XCTestCase {
    func testCurrentTrainingWindowAndLocalizedStrengthSourceRemainDistinct() throws {
        let now = Date(timeIntervalSince1970: 1_793_102_400)
        func workout(daysAgo: Int, sport: String, source: String, minutes: Double, km: Double?) -> WorkoutRow {
            let ts = Int(now.timeIntervalSince1970) - daysAgo * 86_400
            return WorkoutRow(startTs: ts, endTs: ts + Int(minutes * 60), sport: sport, source: source,
                durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                distanceM: km.map { $0 * 1000 }, zonesJSON: nil, notes: nil, steps: nil)
        }
        let rows = [workout(daysAgo: 100, sport: "Running", source: "manual", minutes: 120, km: 21),
                    workout(daysAgo: 4, sport: "Running", source: "manual", minutes: 30, km: 5),
                    workout(daysAgo: 2, sport: "Krafttraining", source: "hevy", minutes: 60, km: nil)]
        let values = GoalMeasurements.values(workouts: rows, weights: [], stress: [], days: [], hardSetsPerWeek: 8, now: now)
        XCTAssertEqual(values[.run]?.value, 5)
        XCTAssertEqual(values[.consistency]?.value, 0.5)
        XCTAssertEqual(values[.strength]?.value, 15)
        XCTAssertEqual(values[.hardSets]?.value, 8)
        XCTAssertNil(values[.weight])
        XCTAssertNil(values[.stress])
        XCTAssertNil(values[.sleep])
    }
}
