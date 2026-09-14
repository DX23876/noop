import XCTest
import StrandTraining
@testable import WhoopStore

final class NativeTrainingStoreTests: XCTestCase {
    func testExerciseAndRoutineRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let exercise = TrainingExercise(id: "noop:bench", title: "Bench Press", mode: .weightReps,
            primaryMuscleId: "chest", secondaryMuscleIds: ["triceps", "shoulders"],
            equipmentIds: ["barbell"], instructions: ["Set the rack height."], source: .noop)
        try await store.upsertTrainingExercises([exercise], nowTs: 10)
        let storedExercises = try await store.trainingExercises()
        XCTAssertEqual(storedExercises, [exercise])

        let superset = UUID()
        let routine = TrainingRoutine(title: "Push", exercises: [
            .init(exerciseId: exercise.id, sets: [
                .init(phase: .warmup, targetWeightKg: 40, repsMin: 8, repsMax: 8),
                .init(targetWeightKg: 80, repsMin: 6, repsMax: 8)
            ], restSeconds: 180, supersetId: superset,
                  progression: .init(policy: .doubleProgression), barWeightKg: 20)
        ], defaultProgression: .init(policy: .linear), createdAt: 1, updatedAt: 2)
        try await store.upsertTrainingRoutine(routine)
        let storedRoutines = try await store.trainingRoutines()
        XCTAssertEqual(storedRoutines, [routine])
    }

    func testDraftIsSingleAndCompletionIsAtomic() async throws {
        let store = try await WhoopStore.inMemory()
        var first = WorkoutDraft(title: "First", startedAt: 100, plannedDay: "2026-09-13")
        try await store.saveWorkoutDraft(first)
        let second = WorkoutDraft(title: "Second", startedAt: 200, plannedDay: "2026-09-14")
        try await store.saveWorkoutDraft(second)
        let storedSecond = try await store.workoutDraft()
        XCTAssertEqual(storedSecond?.id, second.id)

        var set = NativeWorkoutSet(index: 0, weightKg: 100, reps: 5)
        set.isCompleted = true
        first.exercises = [.init(exerciseId: "squat", sets: [set])]
        try await store.saveWorkoutDraft(first)
        let workout = try NativeWorkoutEngine.complete(draft: first, endTs: 500, sessionRPE: 8)
        try await store.completeNativeWorkout(workout)
        let storedDraft = try await store.workoutDraft()
        let storedWorkouts = try await store.nativeWorkouts(from: 0, to: 1_000)
        XCTAssertNil(storedDraft)
        XCTAssertEqual(storedWorkouts, [workout])
    }

    func testPrunesOnlyOldDraft() async throws {
        let store = try await WhoopStore.inMemory()
        let draft = WorkoutDraft(title: "Draft", startedAt: 100, plannedDay: "2026-09-13", updatedAt: 100)
        try await store.saveWorkoutDraft(draft)
        let retainedCount = try await store.pruneWorkoutDrafts(olderThan: 99)
        let prunedCount = try await store.pruneWorkoutDrafts(olderThan: 101)
        XCTAssertEqual(retainedCount, 0)
        XCTAssertEqual(prunedCount, 1)
    }

    func testScheduleAndOverrideBuildEffectivePlan() async throws {
        let store = try await WhoopStore.inMemory()
        let a = TrainingRoutine(title: "A")
        let b = TrainingRoutine(title: "B")
        try await store.upsertTrainingRoutine(a)
        try await store.upsertTrainingRoutine(b)
        try await store.replaceTrainingSchedule([.monday: [a.id, b.id]])
        try await store.replaceTrainingDayOverride(.init(day: "2026-09-14", routineIds: [b.id]))

        let plan = try await store.trainingPlan()
        XCTAssertEqual(plan.effectiveRoutineIds(day: "2026-09-07", weekday: .monday), [a.id, b.id])
        XCTAssertEqual(plan.effectiveRoutineIds(day: "2026-09-14", weekday: .monday), [b.id])

        try await store.replaceTrainingDayOverride(.init(day: "2026-09-14", isRest: true))
        let restPlan = try await store.trainingPlan()
        XCTAssertEqual(restPlan.effectiveRoutineIds(day: "2026-09-14", weekday: .monday), [])
    }
}
