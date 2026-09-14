import XCTest
@testable import StrandTraining

final class StrandTrainingTests: XCTestCase {
    func testLastPerformancePrefillPreservesExplicitTargets() {
        let id = UUID()
        let old = NativeWorkout(id: UUID(), title: "Old", startedAt: 100, endedAt: 200,
            plannedDay: "1970-01-01", routineIds: [], exercises: [
                .init(exerciseId: "press", sets: [
                    .init(index: 0, weightKg: 80, reps: 8, durationS: 45, isCompleted: true)
                ])], tracker: nil)
        var draft = WorkoutDraft(id: id, title: "New", startedAt: 300,
            plannedDay: "1970-01-01", exercises: [
                .init(exerciseId: "press", sets: [
                    .init(index: 0, weightKg: 82.5, reps: nil)
                ])])

        NativeWorkoutEngine.prefillLastPerformance(&draft, history: [old])

        XCTAssertEqual(draft.exercises[0].sets[0].weightKg, 82.5)
        XCTAssertEqual(draft.exercises[0].sets[0].reps, 8)
        XCTAssertEqual(draft.exercises[0].sets[0].durationS, 45)
    }

    func testLastPerformancePrefillKeepsExplicitUnilateralTargets() {
        let old = NativeWorkout(id: UUID(), title: "Old", startedAt: 100, endedAt: 200,
            plannedDay: "1970-01-01", routineIds: [], exercises: [
                .init(exerciseId: "split-squat", sets: [
                    .init(index: 0, weightKg: 20, leftReps: 10, rightReps: 8, isCompleted: true)
                ])], tracker: nil)
        var draft = WorkoutDraft(title: "New", startedAt: 300, plannedDay: "1970-01-01",
            exercises: [.init(exerciseId: "split-squat", sets: [
                .init(index: 0, weightKg: nil, leftReps: 12, rightReps: 12)
            ])])

        NativeWorkoutEngine.prefillLastPerformance(&draft, history: [old])

        XCTAssertEqual(draft.exercises[0].sets[0].weightKg, 20)
        XCTAssertEqual(draft.exercises[0].sets[0].leftReps, 12)
        XCTAssertEqual(draft.exercises[0].sets[0].rightReps, 12)
        XCTAssertNil(draft.exercises[0].sets[0].reps)
    }

    func testCatalogueArchiveRequiresVersionAndKeepsRightsMetadata() throws {
        let rights = ExerciseContentRights(provider: "Local pack", licence: "MIT",
                                           allowsOfflineCache: true, allowsRedistribution: true)
        let archive = ExerciseCatalogArchive(provider: "Local pack", rights: rights,
            exercises: [TrainingExercise(id: "local:squat", title: "Squat", mode: .weightReps)])
        let decoded = try ExerciseCatalogArchive.decode(JSONEncoder().encode(archive))
        XCTAssertEqual(decoded.rights, rights)
        XCTAssertEqual(decoded.exercises.first?.id, "local:squat")

        let future = ExerciseCatalogArchive(formatVersion: 2, provider: "Future", rights: rights, exercises: [])
        XCTAssertThrowsError(try ExerciseCatalogArchive.decode(JSONEncoder().encode(future)))
    }

    func testPlanArchiveContainsOnlyRequiredExercisesAndNoDateOverrides() throws {
        let used = TrainingExercise(id: "noop:squat", title: "Squat", mode: .weightReps)
        let unused = TrainingExercise(id: "noop:curl", title: "Curl", mode: .weightReps)
        let routine = TrainingRoutine(title: "A", exercises: [
            RoutineExercise(exerciseId: used.id, sets: [.init(repsMin: 5, repsMax: 5)])
        ])
        let plan = TrainingPlan(routines: [routine], schedule: [.monday: [routine.id]],
                                overrides: [.init(day: "2026-09-14", isRest: true)])
        let archive = TrainingPlanArchive(exportedAt: 1, plan: plan, exercises: [used, unused])
        let decoded = try TrainingPlanArchive.decode(archive.encoded())
        XCTAssertEqual(decoded.exercises.map(\.id), [used.id])
        XCTAssertTrue(decoded.plan.overrides.isEmpty)
        XCTAssertEqual(decoded.plan.schedule[.monday], [routine.id])
    }

    func testStrongCSVImportGroupsSetsWithoutPersistingMedia() throws {
        let csv = """
        Date,Workout Name,Exercise Name,Weight,Reps,RPE,Notes
        2026-09-12 18:00,"Push, short",Bench Press,80,8,8,steady
        2026-09-12 18:00,"Push, short",Bench Press,82.5,7,9,
        """
        let result = try TrainingCSVImporter.parse(Data(csv.utf8), format: .strong)
        XCTAssertEqual(result.workouts.count, 1)
        XCTAssertEqual(result.workouts[0].title, "Push, short")
        XCTAssertEqual(result.workouts[0].source, .strong)
        XCTAssertEqual(result.workouts[0].exercises[0].sets.count, 2)
        XCTAssertEqual(result.workouts[0].exercises[0].sets[1].weightKg, 82.5)
        XCTAssertNil(result.exercises[0].mediaId)
    }

    func testTwentyYearHistoryEstimateStaysInsideBudget() {
        let estimate = TrainingStorageBudget.estimatedHistoryBytes()
        XCTAssertLessThan(estimate, TrainingStorageBudget.twentyYearTargetBytes)
    }

    func testEffortScalesShareProximity() {
        XCTAssertEqual(TrainingEffortRating(scale: .rpe, value: 8)?.proximityToFailure, 0.6)
        XCTAssertEqual(TrainingEffortRating(scale: .rir, value: 2)?.proximityToFailure, 0.6)
        XCTAssertNil(TrainingEffortRating(scale: .rpe, value: 11))
    }

    func testDayOverrideReplacesWeekWithoutMutatingIt() {
        let a = TrainingRoutine(title: "Push")
        let b = TrainingRoutine(title: "Pull")
        let plan = TrainingPlan(routines: [a, b], schedule: [.monday: [a.id]],
                                overrides: [.init(day: "2026-09-14", routineIds: [b.id])])
        XCTAssertEqual(plan.effectiveRoutineIds(day: "2026-09-14", weekday: .monday), [b.id])
        XCTAssertEqual(plan.effectiveRoutineIds(day: "2026-09-21", weekday: .monday), [a.id])
    }

    func testCombinedRoutineDraftKeepsOriginAndWarmups() {
        let group = UUID()
        let push = TrainingRoutine(title: "Push", exercises: [
            .init(exerciseId: "bench", sets: [
                .init(phase: .warmup, targetWeightKg: 40, repsMin: 8),
                .init(targetWeightKg: 80, repsMin: 6)
            ], supersetId: group)
        ])
        let accessories = TrainingRoutine(title: "Accessories", exercises: [
            .init(exerciseId: "row", sets: [.init(targetWeightKg: 60, repsMin: 10)], supersetId: group)
        ], excludeFromProgression: true)
        let draft = NativeWorkoutEngine.draft(title: "Push + Accessories", day: "2026-09-13",
                                              startTs: 100, routines: [push, accessories])
        XCTAssertEqual(draft.routineIds, [push.id, accessories.id])
        XCTAssertEqual(draft.exercises.count, 2)
        XCTAssertEqual(draft.exercises[0].sets[0].phase, .warmup)
        XCTAssertTrue(draft.exercises[1].excludeFromProgression)
    }

    func testRemovingSupersetMemberDissolvesSingleRemainder() throws {
        var draft = WorkoutDraft(title: "Test", startedAt: 1, plannedDay: "2026-09-13",
                                 exercises: [.init(exerciseId: "a"), .init(exerciseId: "b")])
        try NativeWorkoutEngine.formSuperset(draft.exercises.map(\.id), in: &draft)
        XCTAssertNotNil(draft.exercises[0].supersetId)
        try NativeWorkoutEngine.removeExercise(draft.exercises[0].id, from: &draft)
        XCTAssertNil(draft.exercises[0].supersetId)
    }

    func testAppendingUnilateralSetKeepsSidesButClearsPerformedState() throws {
        let exerciseId = UUID()
        let effort = try XCTUnwrap(TrainingEffortRating(scale: .rir, value: 2))
        let completed = NativeWorkoutSet(index: 0, weightKg: 24, leftReps: 10, rightReps: 8,
                                         effort: effort, isCompleted: true)
        var draft = WorkoutDraft(title: "Split squat", startedAt: 1,
                                 plannedDay: "1970-01-01",
                                 exercises: [.init(id: exerciseId, exerciseId: "split-squat",
                                                   sets: [completed])])

        try NativeWorkoutEngine.appendSet(to: exerciseId, in: &draft)

        let added = try XCTUnwrap(draft.exercises.first?.sets.last)
        XCTAssertNotEqual(added.id, completed.id)
        XCTAssertEqual(added.weightKg, 24)
        XCTAssertEqual(added.leftReps, 10)
        XCTAssertEqual(added.rightReps, 8)
        XCTAssertNil(added.reps)
        XCTAssertNil(added.effort)
        XCTAssertFalse(added.isCompleted)
    }

    func testCompletionDropsUnfinishedRowsAndRejectsEmptyWorkout() throws {
        var completed = NativeWorkoutSet(index: 0, weightKg: 100, reps: 5)
        completed.isCompleted = true
        let pending = NativeWorkoutSet(index: 1, weightKg: 100, reps: 5)
        let draft = WorkoutDraft(title: "Lift", startedAt: 100, plannedDay: "2026-09-13",
                                 exercises: [.init(exerciseId: "squat", sets: [completed, pending])])
        let workout = try NativeWorkoutEngine.complete(draft: draft, endTs: 200, sessionRPE: 8)
        XCTAssertEqual(workout.exercises[0].sets.count, 1)

        XCTAssertThrowsError(try NativeWorkoutEngine.complete(
            draft: .init(title: "Empty", startedAt: 100, plannedDay: "2026-09-13"), endTs: 200))
    }

    func testDraftRoundTripKeepsBackdatedEndAndOldDraftCanOmitIt() throws {
        let draft = WorkoutDraft(title: "Past", startedAt: 100, plannedDay: "1970-01-01",
                                 plannedEndTs: 3_700)
        let decoded = try JSONDecoder().decode(WorkoutDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.plannedEndTs, 3_700)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        object.removeValue(forKey: "plannedEndTs")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(WorkoutDraft.self, from: legacy).plannedEndTs)
    }

    func testLinearAndDoubleProgression() {
        let success = ProgressionSession(weightKg: 100, completedReps: [6, 6, 6],
                                         targetReps: [6, 6, 6])
        var config = ProgressionConfiguration(policy: .linear, weightIncrementKg: 2.5)
        XCTAssertEqual(TrainingProgressionEngine.next(configuration: config, history: [success],
                                                       mode: .weightReps).weightKg, 102.5)
        config.policy = .doubleProgression
        config.repsMin = 6
        config.repsMax = 10
        let top = ProgressionSession(weightKg: 100, completedReps: [10, 10, 10],
                                     targetReps: [10, 10, 10])
        let prescription = TrainingProgressionEngine.next(configuration: config, history: [top],
                                                           mode: .weightReps)
        XCTAssertEqual(prescription.weightKg, 102.5)
        XCTAssertEqual(prescription.reps, 6)
        XCTAssertEqual(prescription.reason, .topOfRepRange)
    }

    func testBodyweightProgressesRepsThenSets() {
        let config = ProgressionConfiguration(policy: .linear, repsMin: 6, repsMax: 10,
                                              bodyweightMaxSets: 4)
        let top = ProgressionSession(weightKg: nil, completedReps: [10, 10, 10],
                                     targetReps: [10, 10, 10])
        let p = TrainingProgressionEngine.next(configuration: config, history: [top],
                                               mode: .bodyweightReps)
        XCTAssertEqual(p.reps, 6)
        XCTAssertEqual(p.setCount, 4)
        XCTAssertEqual(p.reason, .addSet)
    }

    func testGreyskullExceptionalAMRAPDoublesIncrement() {
        let config = ProgressionConfiguration(policy: .greyskullLP, weightIncrementKg: 2.5)
        let session = ProgressionSession(weightKg: 80, completedReps: [5, 5, 11],
                                         targetReps: [5, 5, 5])
        let p = TrainingProgressionEngine.next(configuration: config, history: [session],
                                               mode: .weightReps)
        XCTAssertEqual(p.weightKg, 85)
        XCTAssertEqual(p.reason, .exceptionalAMRAP)
    }

    func testDeloadAfterConfiguredFailures() {
        let config = ProgressionConfiguration(policy: .linear, weightIncrementKg: 2.5,
                                              failuresBeforeDeload: 2, deloadFactor: 0.9)
        let failed = ProgressionSession(weightKg: 100, completedReps: [4], targetReps: [5])
        let p = TrainingProgressionEngine.next(configuration: config, history: [failed, failed],
                                               mode: .weightReps)
        XCTAssertEqual(p.weightKg, 90)
        XCTAssertEqual(p.reason, .stalledDeload)
    }

    func testPlateCalculatorReportsExactAndRemainder() {
        let exact = PlateCalculator.loading(totalKg: 100, barKg: 20)
        XCTAssertEqual(exact?.platesPerSideKg.reduce(0, +), 40)
        XCTAssertEqual(exact?.achievableTotalKg, 100)
        XCTAssertEqual(exact?.remainderKg, 0)
        let partial = PlateCalculator.loading(totalKg: 101, barKg: 20)
        XCTAssertEqual(partial?.achievableTotalKg, 100)
        XCTAssertEqual(partial?.remainderKg, 1)
    }

    func testSourceCapabilitiesRoundTrip() throws {
        let value: TrainingSourceCapabilities = [.workoutEnvelope, .heartRate, .distance]
        let decoded = try JSONDecoder().decode(TrainingSourceCapabilities.self,
                                               from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }
}
