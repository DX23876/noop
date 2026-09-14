import XCTest
import StrandTraining
import WhoopStore
@testable import Strand

final class NativeTrainingProjectionTests: XCTestCase {
    func testNativeWorkoutProjectsSetsEffortMusclesAndTrackerWithoutPersistenceTwin() {
        let exercise = TrainingExercise(
            id: "user:incline", title: "Incline press", mode: .weightReps,
            primaryMuscleId: "upper_chest", secondaryMuscleIds: ["front_delts", "triceps"],
            equipmentIds: ["barbell"], source: .user)
        let effort = TrainingEffortRating(scale: .rir, value: 2)
        let native = NativeWorkout(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Push", startedAt: 1_000, endedAt: 4_000,
            plannedDay: "1970-01-01", routineIds: [],
            exercises: [.init(exerciseId: exercise.id, sets: [
                .init(index: 0, phase: .warmup, weightKg: 20, reps: 10, isCompleted: true),
                .init(index: 1, weightKg: 60, reps: 8, effort: effort, isCompleted: true),
                .init(index: 2, weightKg: 24, leftReps: 10, rightReps: 8, isCompleted: true),
            ])],
            tracker: .init(trackerId: "whoop-gym", model: "Gym band", confidence: .userSelected,
                           capabilities: [.heartRate]))

        let result = NativeTrainingProjection.strength(workouts: [native], exercises: [exercise])
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.workouts[0].source, .noopNative)
        XCTAssertEqual(result.workouts[0].exercises[0].sets[0].type, .warmup)
        XCTAssertEqual(result.workouts[0].exercises[0].sets[1].rpe, 8)
        XCTAssertEqual(result.workouts[0].exercises[0].sets[2].reps, 8)
        XCTAssertEqual(result.templates[exercise.id]?.primaryMuscleGroup, .chest)
        XCTAssertEqual(result.templates[exercise.id]?.equipment, .barbell)

        let row = NativeTrainingProjection.workoutRow(native)
        XCTAssertEqual(row.source, "native-training:whoop-gym")
        XCTAssertEqual(row.sport, "Strength Training")
        XCTAssertEqual(row.durationS, 3_000)
    }
}
