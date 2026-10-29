import XCTest
@testable import StrandTraining

final class LoadedMeasurementTests: XCTestCase {
    func testAvailableEquipmentRequiresEveryToolAndCanonicalizesAliases() {
        XCTAssertTrue(TrainingEquipmentCatalog.matches(["body-weight"], available: ["dumbbell"]))
        XCTAssertTrue(TrainingEquipmentCatalog.matches(["olympic-barbell", "bench"], available: ["barbell", "bench"]))
        XCTAssertFalse(TrainingEquipmentCatalog.matches(["barbell", "bench"], available: ["barbell"]))
        XCTAssertTrue(TrainingEquipmentCatalog.matches(["machine"], available: []))
    }

    func testAHandsFreeCompletionRequiresBothLoadedMeasurements() {
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, weightKg: 20), mode: .weightDuration))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, durationS: 45), mode: .weightDuration))
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, weightKg: 20, durationS: 45), mode: .weightDuration))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, weightKg: 30), mode: .distanceWeight))
        XCTAssertFalse(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, distanceM: 25), mode: .distanceWeight))
        XCTAssertTrue(NativeWorkoutEngine.hasLoggableValues(.init(index: 0, weightKg: 30, distanceM: 25), mode: .distanceWeight))
    }

    func testFreshNonRepetitionSetsDoNotInventRepetitions() {
        for mode in [TrainingMeasurementMode.duration, .distanceDuration, .weightDuration, .distanceWeight] {
            let plans = RoutineSetPlan.defaults(for: mode)
            XCTAssertEqual(plans.count, 3)
            XCTAssertTrue(plans.allSatisfy { $0.repsMin == nil && $0.repsMax == nil })
            let sets = NativeWorkoutEngine.setsForAddedExercise(lastPerformance: [], unilateral: true, workingSets: 3, mode: mode)
            XCTAssertTrue(sets.allSatisfy { $0.reps == nil && $0.leftReps == nil && $0.rightReps == nil })
        }
        XCTAssertEqual(RoutineSetPlan.defaults(for: .weightReps).first?.repsMin, 8)
    }

    func testLoadedTimeKeepsWeightAndCannotAcquireRepetitionProgression() {
        let history = [ProgressionSession(weightKg: 20, completedReps: [], targetReps: [], durationS: 45, targetDurationS: 45)]
        let repeated = TrainingProgressionEngine.next(configuration: .init(policy: .doubleProgression), history: history, mode: .weightDuration,
            currentWeightKg: 20, currentSets: 1, currentDurationS: 45)
        XCTAssertNil(repeated.reps)
        XCTAssertEqual(repeated.weightKg, 20)
        XCTAssertEqual(repeated.durationS, 45)
        let timed = TrainingProgressionEngine.next(configuration: .init(policy: .time, durationIncrementS: 5), history: history,
            mode: .weightDuration, currentWeightKg: 20, currentSets: 1, currentDurationS: 45)
        XCTAssertEqual(timed.durationS, 50)
        XCTAssertEqual(timed.weightKg, 20)
        XCTAssertNil(timed.reps)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .weightDuration, equipmentIds: ["kettlebell"]), .perImplement)
    }
}
