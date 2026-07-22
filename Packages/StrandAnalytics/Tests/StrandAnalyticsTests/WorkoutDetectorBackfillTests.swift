import XCTest
@testable import StrandAnalytics
import WhoopStore

/// #510: a detected bout's own computed avgHR/calories/maxHR/strain must fill ONLY the fields a
/// colliding real (manual/imported) workout is missing — never override anything already present.
/// Regression for the report where manually-entered workouts silently showed no HR/calories even
/// though the detector had already computed a valid average for that exact window.
final class WorkoutDetectorBackfillTests: XCTestCase {

    private func manualRow(avgHr: Int? = nil, maxHr: Int? = nil, energyKcal: Double? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: 1_000, endTs: 1_600, sport: "Running", source: "manual",
                   durationS: 600, energyKcal: energyKcal, avgHr: avgHr, maxHr: maxHr,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    func testFillsAllMissingFields() {
        let real = manualRow()
        let filled = WorkoutDetector.backfillWorkout(real, avgBpm: 150, peakHR: 170, caloriesKcal: 80.0, strain: 9.5)
        XCTAssertEqual(filled.avgHr, 150)
        XCTAssertEqual(filled.maxHr, 170)
        XCTAssertEqual(filled.energyKcal, 80.0)
        XCTAssertEqual(filled.strain, 9.5)
        // The rest of the row is carried over untouched.
        XCTAssertEqual(filled.startTs, real.startTs)
        XCTAssertEqual(filled.sport, real.sport)
        XCTAssertEqual(filled.source, real.source)
    }

    func testNeverOverridesFieldsAlreadyPresent() {
        // The user typed an Avg HR and calories by hand; only maxHr/strain are missing.
        let real = manualRow(avgHr: 140, maxHr: nil, energyKcal: 50.0, strain: nil)
        let filled = WorkoutDetector.backfillWorkout(real, avgBpm: 150, peakHR: 170, caloriesKcal: 80.0, strain: 9.5)
        XCTAssertEqual(filled.avgHr, 140, "a user-typed value must never be overwritten")
        XCTAssertEqual(filled.energyKcal, 50.0, "a user-typed value must never be overwritten")
        XCTAssertEqual(filled.maxHr, 170, "a missing field must still be filled")
        XCTAssertEqual(filled.strain, 9.5, "a missing field must still be filled")
    }

    func testRowWithEverythingAlreadyPresentIsUnchanged() {
        let real = manualRow(avgHr: 140, maxHr: 160, energyKcal: 50.0, strain: 8.0)
        let filled = WorkoutDetector.backfillWorkout(real, avgBpm: 150, peakHR: 170, caloriesKcal: 80.0, strain: 9.5)
        XCTAssertEqual(filled, real, "nothing to fill -> byte-identical row, so the caller can skip the write")
    }
}
