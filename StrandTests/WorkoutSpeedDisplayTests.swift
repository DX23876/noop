import XCTest
import StrandAnalytics
@testable import Strand

final class WorkoutSpeedDisplayTests: XCTestCase {
    func testBeforeTheFirstMeasurementThereIsNoInventedValue() {
        let id = UUID()
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: nil)
        XCTAssertNil(display.value(workoutID: id))
    }

    func testDisplayHoldsSpeedWhenFreshMeasurementExpires() {
        let id = UUID()
        var timeline = WorkoutRecordingTimeline()
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(15, at: 5, segment: 0)
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: timeline.currentSpeedMps(at: 5, lastFixAge: 0))
        XCTAssertEqual(display.value(workoutID: id), 3)

        let fresh = timeline.currentSpeedMps(at: 11, lastFixAge: 6)
        XCTAssertNil(fresh, "Coaching must not receive the held display value.")
        display.update(workoutID: id, speedMps: fresh)
        XCTAssertEqual(display.value(workoutID: id), 3, "A brief gap must not replace the number with a dash.")
    }

    func testPauseAndRecoveryWarmupKeepThePreviousNumber() {
        let id = UUID()
        var timeline = WorkoutRecordingTimeline()
        timeline.recordDistance(0, at: 0, segment: 0)
        timeline.recordDistance(15, at: 5, segment: 0)
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: timeline.currentSpeedMps(at: 5, lastFixAge: 0))
        timeline.pause()
        display.update(workoutID: id, speedMps: nil)
        XCTAssertEqual(display.value(workoutID: id), 3)
        timeline.recordDistance(15, at: 5, segment: 1)
        timeline.recordDistance(19, at: 7, segment: 1)
        display.update(workoutID: id, speedMps: timeline.currentSpeedMps(at: 7, lastFixAge: 0))
        XCTAssertEqual(display.value(workoutID: id), 3)
        timeline.recordDistance(25, at: 10, segment: 1)
        display.update(workoutID: id, speedMps: timeline.currentSpeedMps(at: 10, lastFixAge: 0))
        XCTAssertEqual(display.value(workoutID: id), 2)
    }

    func testLongSignalGapHoldsUntilAnotherValidMeasurement() {
        let id = UUID()
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: 3)
        for _ in 0..<1000 { display.update(workoutID: id, speedMps: nil) }
        XCTAssertEqual(display.value(workoutID: id), 3)
        display.update(workoutID: id, speedMps: 4)
        XCTAssertEqual(display.value(workoutID: id), 4)
    }

    func testInvalidMeasurementsCannotReplaceThePreviousNumber() {
        let id = UUID()
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: 3)
        for value in [Double.nan, .infinity, -.infinity, 0, -1] {
            display.update(workoutID: id, speedMps: value)
            XCTAssertEqual(display.value(workoutID: id), 3)
        }
    }

    func testAReplacementWorkoutCannotInheritThePreviousReading() {
        let first = UUID(), second = UUID()
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: first, speedMps: 3)
        XCTAssertNil(display.value(workoutID: second))
        display.update(workoutID: second, speedMps: nil)
        XCTAssertNil(display.value(workoutID: second))
        XCTAssertNil(display.value(workoutID: first))
    }

    func testEndingAndRestartingEvenTheSameIdentityClearsTheNumber() {
        let id = UUID()
        var display = WorkoutSpeedDisplay()
        display.update(workoutID: id, speedMps: 3)
        display.update(workoutID: nil, speedMps: nil)
        XCTAssertNil(display.value(workoutID: nil))
        display.update(workoutID: id, speedMps: nil)
        XCTAssertNil(display.value(workoutID: id))
    }
}
