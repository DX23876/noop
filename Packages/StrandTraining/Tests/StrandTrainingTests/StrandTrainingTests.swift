import XCTest
@testable import StrandTraining

final class StrandTrainingTests: XCTestCase {
    func testRoutineMoveKeepsSupersetTogether() {
        let group = UUID()
        var exercises = [
            RoutineExercise(exerciseId: "a", sets: [], supersetId: group),
            RoutineExercise(exerciseId: "b", sets: [], supersetId: group),
            RoutineExercise(exerciseId: "c", sets: []),
            RoutineExercise(exerciseId: "d", sets: []),
        ]
        RoutineEditing.move(&exercises, from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(exercises.map(\.exerciseId), ["c", "d", "a", "b"])
        XCTAssertEqual(exercises.suffix(2).compactMap(\.supersetId), [group, group])
    }

    func testRoutineCopyRegeneratesNestedIdentifiers() {
        let group = UUID()
        let original = TrainingRoutine(title: "Push", exercises: [
            RoutineExercise(exerciseId: "bench", sets: [.init(repsMin: 8, repsMax: 10)],
                            supersetId: group),
            RoutineExercise(exerciseId: "row", sets: [.init(repsMin: 8, repsMax: 10)],
                            supersetId: group),
        ])
        let copy = RoutineEditing.duplicate(original, title: "Push copy", now: 123)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.exercises[0].id, original.exercises[0].id)
        XCTAssertNotEqual(copy.exercises[0].sets[0].id, original.exercises[0].sets[0].id)
        XCTAssertEqual(copy.exercises[0].supersetId, copy.exercises[1].supersetId)
        XCTAssertNotEqual(copy.exercises[0].supersetId, group)
        XCTAssertEqual(copy.exercises.map(\.exerciseId), ["bench", "row"])
    }
    func testReviewedExerciseAnatomyCatalogueHasNoInvalidMappings() {
        XCTAssertEqual(ExerciseAnatomyCatalog.validationIssues(), [])
        XCTAssertGreaterThanOrEqual(ExerciseAnatomyCatalog.all.count, 45)
    }

    func testEveryBundledStarterExerciseHasReviewedDetailedAnatomy() {
        for exercise in TrainingStarterCatalog.exercises {
            let anatomy = TrainingMuscleProjection.anatomy(for: exercise)
            XCTAssertEqual(anatomy?.confidence, .reviewed, exercise.title)
        }
    }

    func testExerciseAnatomyResolvesProviderIdentityAndTranslatedAliasesOffline() throws {
        let provider = try XCTUnwrap(ExerciseAnatomyCatalog.resolve(
            title: "ignored", source: .noopNative, sourceId: "noop:barbell-bench-press"))
        XCTAssertEqual(provider.id, "barbell-bench-press")
        XCTAssertEqual(provider.primaryMuscleIds, ["chest"])

        let translated = try XCTUnwrap(ExerciseAnatomyCatalog.resolve(title: "Rumänisches Kreuzheben"))
        XCTAssertEqual(translated.id, "romanian-deadlift")
        XCTAssertEqual(Set(translated.primaryMuscleIds), Set(["glutes", "hamstrings"]))
        XCTAssertTrue(translated.stabilizerMuscleIds.contains("lats"))
    }

    func testStabilizersNeverOverlapCreditedMusclesInReviewedEntry() throws {
        let row = try XCTUnwrap(ExerciseAnatomyCatalog.resolve(title: "Face Pull"))
        let credited = Set(row.primaryMuscleIds + row.secondaryMuscleIds)
        XCTAssertTrue(credited.isDisjoint(with: row.stabilizerMuscleIds))
    }
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

    func testLegacyDraftDecodesWithoutLifecycleAndSetSemantics() throws {
        let origin = UUID()
        let cluster = UUID()
        let draft = WorkoutDraft(
            title: "Interrupted", startedAt: 100, plannedDay: "1970-01-01",
            exercises: [.init(exerciseId: "row", sets: [
                .init(id: origin, index: 0, weightKg: 50, reps: 8, clusterId: cluster),
                .init(index: 1, intensifier: .restPause, weightKg: 50, reps: 3,
                      clusterId: cluster, parentSetId: origin, segmentIndex: 1)
            ], equipmentSnapshot: .init(equipmentIds: ["cable"], loadSemantics: .machineValue))],
            cursor: .init(exerciseId: UUID(), setId: origin),
            timer: .init(kind: .rest, startedAtTs: 110, endsAtTs: 170),
            interruptionReason: .appBackgrounded, lifecycleVersion: 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(draft)) as? [String: Any])
        ["cursor", "timer", "interruptionReason", "lifecycleVersion"].forEach {
            object.removeValue(forKey: $0)
        }
        var exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        exercises[0].removeValue(forKey: "equipmentSnapshot")
        var sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        for index in sets.indices {
            ["targetDurationS", "clusterId", "parentSetId", "segmentIndex"].forEach {
                sets[index].removeValue(forKey: $0)
            }
        }
        exercises[0]["sets"] = sets
        object["exercises"] = exercises

        let legacy = try JSONDecoder().decode(WorkoutDraft.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.cursor)
        XCTAssertNil(legacy.timer)
        XCTAssertNil(legacy.interruptionReason)
        XCTAssertNil(legacy.lifecycleVersion)
        XCTAssertNil(legacy.exercises[0].equipmentSnapshot)
        XCTAssertNil(legacy.exercises[0].sets[1].parentSetId)
    }

    func testExerciseLoadSemanticsAndDraftEquipmentSnapshot() {
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .weightReps,
                                                           equipmentIds: ["barbell"]),
                       .totalExternalLoad)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .weightReps,
                                                           equipmentIds: ["dumbbell"]),
                       .perImplement)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .weightReps,
                                                           equipmentIds: ["machine"]),
                       .machineValue)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .weightedBodyweight), .addedBodyweight)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .assistedBodyweight), .assistance)
        XCTAssertEqual(ExerciseLoadSemantics.defaultValue(for: .bodyweightReps), .bodyweightOnly)

        let exercise = TrainingExercise(id: "db-press", title: "Press", mode: .weightReps,
                                        equipmentIds: ["dumbbell"])
        let routine = TrainingRoutine(title: "Push", exercises: [
            .init(exerciseId: exercise.id, sets: [.init()], barWeightKg: 0)
        ])
        let draft = NativeWorkoutEngine.draft(
            title: "Push", day: "1970-01-01", startTs: 1, routines: [routine],
            exerciseDefinitions: [exercise.id: exercise])
        XCTAssertEqual(draft.exercises[0].equipmentSnapshot?.loadSemantics, .perImplement)
        XCTAssertNil(draft.exercises[0].equipmentSnapshot?.implementCount)
    }

    func testWarmupRestAndTechniqueClustersRemainExplicit() throws {
        let plans: [RoutineSetPlan] = [
            .init(phase: .warmup, targetWeightKg: 20, repsMin: 10),
            .init(targetWeightKg: 80, repsMin: 8),
            .init(intensifier: .dropSet, targetWeightKg: 60, repsMin: 6),
            .init(intensifier: .restPause, targetWeightKg: 60, repsMin: 3)
        ]
        let sets = NativeWorkoutEngine.plannedSets(plans)
        let exercise = NativeWorkoutExercise(exerciseId: "press", sets: sets,
                                             restSeconds: 150, warmupRestSeconds: 45)
        XCTAssertEqual(NativeWorkoutEngine.restSeconds(after: sets[0], in: exercise), 45)
        XCTAssertEqual(NativeWorkoutEngine.restSeconds(after: sets[1], in: exercise), 150)
        XCTAssertEqual(sets[2].parentSetId, sets[1].id)
        XCTAssertEqual(sets[3].parentSetId, sets[1].id)
        XCTAssertEqual(NativeWorkoutEngine.clusters(in: exercise).first?.segmentSetIds,
                       [sets[2].id, sets[3].id])

        var draft = WorkoutDraft(title: "Press", startedAt: 1, plannedDay: "1970-01-01",
                                 exercises: [exercise])
        try NativeWorkoutEngine.appendSegment(to: sets[1].id, intensifier: .restPause, in: &draft)
        let added = try XCTUnwrap(draft.exercises[0].sets.last)
        XCTAssertEqual(added.parentSetId, sets[1].id)
        XCTAssertEqual(added.segmentIndex, 3)
    }

    func testUnilateralTechniqueSegmentAndNewNormalSetKeepSides() throws {
        let origin = NativeWorkoutSet(index: 0, weightKg: 24, leftReps: 9, rightReps: 8)
        var draft = WorkoutDraft(title: "Split squat", startedAt: 1, plannedDay: "1970-01-01",
                                 exercises: [.init(exerciseId: "split-squat", sets: [origin])])
        try NativeWorkoutEngine.appendSegment(to: origin.id, intensifier: .dropSet, in: &draft)
        XCTAssertEqual(draft.exercises[0].sets[1].leftReps, 9)
        XCTAssertEqual(draft.exercises[0].sets[1].rightReps, 8)
        try NativeWorkoutEngine.appendSet(to: draft.exercises[0].id, in: &draft)
        let normal = try XCTUnwrap(draft.exercises[0].sets.last)
        XCTAssertEqual(normal.intensifier, .none)
        XCTAssertNil(normal.parentSetId)
        XCTAssertEqual(normal.leftReps, 9)
        XCTAssertEqual(normal.rightReps, 8)
    }

    func testTimedSetAndTimerKeepTargetSeparateFromResult() throws {
        var set = NativeWorkoutSet(index: 0, targetDurationS: 60, durationS: 53)
        set.isCompleted = true
        let timer = WorkoutTimerState(kind: .timedSet, exerciseId: UUID(), setId: set.id,
                                      startedAtTs: 100, endsAtTs: 160, pausedRemainingSeconds: 7)
        let draft = WorkoutDraft(title: "Core", startedAt: 90, plannedDay: "1970-01-01",
                                 exercises: [.init(exerciseId: "plank", sets: [set])], timer: timer)
        let decoded = try JSONDecoder().decode(WorkoutDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.exercises[0].sets[0].targetDurationS, 60)
        XCTAssertEqual(decoded.exercises[0].sets[0].durationS, 53)
        XCTAssertEqual(decoded.timer, timer)
    }

    func testCompletionValidationAndOptionalSessionRPE() throws {
        let empty = WorkoutDraft(title: "Empty", startedAt: 1, plannedDay: "1970-01-01")
        XCTAssertEqual(NativeWorkoutEngine.completionValidation(for: empty).state, .empty)

        var completed = NativeWorkoutSet(index: 0, reps: 5)
        completed.isCompleted = true
        let pending = NativeWorkoutSet(index: 1, reps: 5)
        let partial = WorkoutDraft(title: "Partial", startedAt: 1, plannedDay: "1970-01-01",
                                   exercises: [.init(exerciseId: "squat", sets: [completed, pending])])
        XCTAssertEqual(NativeWorkoutEngine.completionValidation(for: partial).state, .partial)
        let withoutRPE = try NativeWorkoutEngine.complete(draft: partial, endTs: 2)
        XCTAssertNil(withoutRPE.sessionRPE)
        XCTAssertNil(withoutRPE.sessionRPEOrigin)
        let withRPE = try NativeWorkoutEngine.complete(draft: partial, endTs: 2, sessionRPE: 8)
        XCTAssertEqual(withRPE.sessionRPEOrigin, .workoutCompletion)

        var fullyComplete = partial
        fullyComplete.exercises[0].sets[1].isCompleted = true
        XCTAssertEqual(NativeWorkoutEngine.completionValidation(for: fullyComplete).state, .complete)
    }

    func testSummaryUsesCompletedSetsAndExcludesMergedPauseIntervals() throws {
        var warmup = NativeWorkoutSet(index: 0, phase: .warmup, weightKg: 40, reps: 8)
        warmup.isCompleted = true
        var work = NativeWorkoutSet(index: 1, weightKg: 100, reps: 5)
        work.isCompleted = true
        let pending = NativeWorkoutSet(index: 2, weightKg: 100, reps: 5)
        let workout = NativeWorkout(id: UUID(), title: "Summary", startedAt: 100, endedAt: 1_000,
                                    plannedDay: "1970-01-01", routineIds: [],
                                    exercises: [.init(exerciseId: "squat", sets: [warmup, work, pending])],
                                    tracker: nil,
                                    pauseIntervals: [
                                        .init(startedAtTs: 300, endedAtTs: 400),
                                        .init(startedAtTs: 350, endedAtTs: 500),
                                        .init(startedAtTs: 800, endedAtTs: nil)
                                    ])
        let summary = NativeWorkoutEngine.summary(for: workout)
        XCTAssertEqual(summary.exerciseCount, 1)
        XCTAssertEqual(summary.warmupSetCount, 1)
        XCTAssertEqual(summary.workingSetCount, 1)
        XCTAssertEqual(summary.loadedVolumeKg, 500)
        XCTAssertEqual(summary.elapsedDurationS, 900)
        XCTAssertEqual(summary.activeDurationS, 500)
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

    func testRoutineAndWorkoutPreviewsUseSameCreditsAndExcludeStabilizers() {
        let exercise = TrainingExercise(id: "noop:barbell-bench-press", title: "Bench Press",
                                        mode: .weightReps, source: .noop,
                                        sourceId: "noop:barbell-bench-press")
        let planned = RoutineExercise(exerciseId: exercise.id, sets: [
            .init(phase: .warmup), .init(), .init(), .init()
        ])
        let routine = TrainingRoutine(title: "Push", exercises: [planned])
        let preview = TrainingMuscleProjection.routine(routine, exercises: [exercise.id: exercise])
        XCTAssertEqual(preview["chest"], 3)
        XCTAssertEqual(preview["triceps"], 1.5)
        XCTAssertNil(preview["serratus"])

        var complete = NativeWorkoutSet(index: 0, weightKg: 80, reps: 8)
        complete.isCompleted = true
        let incomplete = NativeWorkoutSet(index: 1, weightKg: 80, reps: 8)
        let workout = NativeWorkout(id: UUID(), title: "Push", startedAt: 1, endedAt: 2,
                                    plannedDay: "1970-01-01", routineIds: [],
                                    exercises: [.init(exerciseId: exercise.id,
                                                      sets: [complete, incomplete])], tracker: nil)
        let summary = TrainingMuscleProjection.workout(workout, exercises: [exercise.id: exercise])
        XCTAssertEqual(summary["chest"], 1)
        XCTAssertEqual(summary["triceps"], 0.5)
        XCTAssertNil(summary["serratus"])
    }

    func testSourceCapabilitiesRoundTrip() throws {
        let value: TrainingSourceCapabilities = [.workoutEnvelope, .heartRate, .distance]
        let decoded = try JSONDecoder().decode(TrainingSourceCapabilities.self,
                                               from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
    }

    func testWarmupPlannerNeverReachesFirstWorkSetAndSkipsBodyweight() {
        let ramp = WarmupPlanner.suggestedSets(firstWorkSetKg: 100, mode: .weightReps,
                                                incrementKg: 2.5, count: 3)
        XCTAssertEqual(ramp.count, 3)
        XCTAssertTrue(ramp.allSatisfy { ($0.targetWeightKg ?? .infinity) < 100 })
        XCTAssertTrue(WarmupPlanner.suggestedSets(firstWorkSetKg: 100, mode: .bodyweightReps,
                                                   incrementKg: 2.5).isEmpty)
    }

    func testTimerDeadlineSurvivesPauseResumeAndAdjustment() {
        let initial = WorkoutTimerCoordinator.start(kind: .rest, seconds: 90, now: 100)
        XCTAssertEqual(WorkoutTimerCoordinator.remaining(initial!, now: 130), 60)
        let paused = WorkoutTimerCoordinator.pause(initial!, now: 130)
        XCTAssertEqual(WorkoutTimerCoordinator.remaining(paused, now: 500), 60)
        let resumed = WorkoutTimerCoordinator.resume(paused, now: 500)
        XCTAssertEqual(resumed.endsAtTs, 560)
        XCTAssertEqual(WorkoutTimerCoordinator.adjust(resumed, by: 15, now: 510).endsAtTs, 575)
    }

    func testProgressionPreservesAnOffGridLoadAndOnlyUsesExplicitEffortTarget() {
        let success = ProgressionSession(weightKg: 101, completedReps: [6], targetReps: [6])
        let linear = ProgressionConfiguration(policy: .linear, weightIncrementKg: 2.5)
        XCTAssertEqual(TrainingProgressionEngine.next(configuration: linear, history: [success],
                                                       mode: .weightReps).weightKg, 103.5)

        let hard = ProgressionSession(weightKg: 100, completedReps: [6], targetReps: [6],
                                      efforts: [TrainingEffortRating(scale: .rpe, value: 10)!])
        XCTAssertEqual(TrainingProgressionEngine.next(configuration: linear, history: [hard],
                                                       mode: .weightReps).reason, .successfulSession)
        var capped = linear
        capped.targetEffort = TrainingEffortRating(scale: .rpe, value: 8)
        XCTAssertEqual(TrainingProgressionEngine.next(configuration: capped, history: [hard],
                                                       mode: .weightReps).reason, .repeatTarget)
    }
}
