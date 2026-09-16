import XCTest
import StrandAnalytics
import StrandTraining
import WhoopStore
@testable import Strand

final class ResolvedStrengthHistoryTests: XCTestCase {
    func testMuscleMetricProjectionKeepsWarmupBoundaryAndReviewedAnatomy() {
        let warmup = HevySet(index: 0, type: .warmup, weightKg: 40, reps: 8,
                             distanceM: nil, durationS: nil, rpe: nil, customMetric: nil)
        let working = HevySet(index: 1, type: .normal, weightKg: 80, reps: 6,
                              distanceM: nil, durationS: nil, rpe: 8, customMetric: nil)
        let sourceExercise = HevyExercise(index: 0, title: "Bench Press", templateId: "bench",
                                          supersetId: nil, notes: nil, sets: [warmup, working])
        let workout = HevyWorkout(id: "workout", title: "Push", routineId: nil, notes: nil,
                                  startTs: 100, endTs: 3_700, updatedAtTs: 3_700,
                                  createdAtTs: 100, exercises: [sourceExercise])
        let anatomy = ExerciseAnatomy(id: "bench-press", title: "Bench Press", mode: .weightReps,
            movementPattern: .horizontalPush, primaryMuscleIds: ["chest"],
            secondaryMuscleIds: ["triceps"], stabilizerMuscleIds: ["serratus"])
        let template = HevyExerciseTemplate(id: "bench", title: "Bench Press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps],
            equipment: .barbell, isCustom: false)
        let session = ResolvedStrengthSession(
            id: "session", workout: workout,
            exercises: [.init(source: sourceExercise, anatomy: anatomy)], canonicalRow: nil)
        let history = ResolvedStrengthHistory(sessions: [session], workouts: [workout],
                                              templates: ["bench": template], historyAvailableFrom: 0)

        let projected = history.muscleMetricSets()

        XCTAssertEqual(projected.count, 2)
        XCTAssertTrue(projected[0].isWarmup)
        XCTAssertFalse(projected[1].isWarmup)
        XCTAssertEqual(projected[1].exerciseId, "bench-press")
        XCTAssertEqual(projected[1].primaryMuscleIds, ["chest"])
        XCTAssertEqual(projected[1].secondaryMuscleIds, ["triceps"])
        XCTAssertEqual(projected[1].stabilizerMuscleIds, ["serratus"])
        XCTAssertNotNil(projected[1].estimatedOneRepMaxKg)
        XCTAssertTrue(projected[1].rpeWasRecorded)
    }

    func testDetailedMuscleLoadCreditsPrimaryAndSecondaryButNotStabilizers() {
        let set = HevySet(index: 0, type: .normal, weightKg: 70, reps: 8,
                          distanceM: nil, durationS: nil, rpe: 10, customMetric: nil)
        let sourceExercise = HevyExercise(index: 0, title: "Bench Press", templateId: "bench",
                                          supersetId: nil, notes: nil, sets: [set])
        let workout = HevyWorkout(id: "workout", title: "Push", routineId: nil, notes: nil,
                                  startTs: 100, endTs: 3_700, updatedAtTs: 3_700,
                                  createdAtTs: 100, exercises: [sourceExercise])
        let anatomy = ExerciseAnatomy(id: "bench", title: "Bench Press", mode: .weightReps,
            movementPattern: .horizontalPush, primaryMuscleIds: ["chest"],
            secondaryMuscleIds: ["triceps"], stabilizerMuscleIds: ["serratus"])
        let template = HevyExerciseTemplate(id: "bench", title: "Bench Press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps],
            equipment: .barbell, isCustom: false)
        let session = ResolvedStrengthSession(
            id: "session", workout: workout,
            exercises: [.init(source: sourceExercise, anatomy: anatomy)], canonicalRow: nil)
        let history = ResolvedStrengthHistory(sessions: [session], workouts: [workout],
                                              templates: ["bench": template])

        let result = DetailedMuscleLoadSnapshot.volume(history: history, from: 0, to: 10_000)

        XCTAssertEqual(result.workingSets, 1)
        XCTAssertEqual(result.mappedSets, 1)
        XCTAssertEqual(result.byMuscle["triceps"] ?? -1, (result.byMuscle["chest"] ?? 0) * 0.5,
                       accuracy: 0.0001)
        XCTAssertNil(result.byMuscle["serratus"])
    }
}
