import XCTest
import GRDB
import StrandTraining
@testable import WhoopStore

final class NativeTrainingStoreTests: XCTestCase {
    func testV66AddsOptionalSummaryPausesWithoutChangingExistingWorkouts() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v65-strength-physiology-lifecycle")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingWorkoutNative
                  (id, title, startedAtTs, endedAtTs, plannedDay, routineIdsJSON,
                   trackerJSON, sessionRPE, note, source)
                VALUES ('legacy-v66', 'Legacy', 100, 200, '1970-01-01', '[]',
                        NULL, NULL, NULL, 'noop_native')
                """)
        }
        try migrator.migrate(queue)
        let value = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT pauseIntervalsJSON FROM trainingWorkoutNative WHERE id = 'legacy-v66'")
        }
        XCTAssertNil(value?["pauseIntervalsJSON"] as String?)
    }

    func testV65AddsOptionalPhysiologyLinkWithoutRewritingWorkouts() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v64-complete-strength-workout-domain")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingWorkoutNative
                  (id, title, startedAtTs, endedAtTs, plannedDay, routineIdsJSON,
                   trackerJSON, sessionRPE, note, source, sessionRPEOrigin)
                VALUES ('legacy-v65', 'Legacy', 100, 200, '1970-01-01', '[]',
                        NULL, NULL, NULL, 'noop_native', NULL)
                """)
        }
        try migrator.migrate(queue)
        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM trainingWorkoutNative WHERE id = 'legacy-v65'")
        }
        XCTAssertNil(row?["trainingSessionId"] as String?)
        XCTAssertNil(row?["physiologyProvider"] as String?)
        XCTAssertNil(row?["hrCoverage"] as Double?)
    }

    func testV64MarksExistingSessionRPEOriginWithoutChangingTheRating() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v63-training-exercise-anatomy-alias")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingWorkoutNative
                  (id, title, startedAtTs, endedAtTs, plannedDay, routineIdsJSON,
                   trackerJSON, sessionRPE, note, source)
                VALUES ('legacy', 'Legacy', 100, 200, '1970-01-01', '[]', NULL, 8, NULL, 'noop_native')
                """)
        }

        try migrator.migrate(queue)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT sessionRPE, sessionRPEOrigin FROM trainingWorkoutNative")
        }
        XCTAssertEqual(row?["sessionRPE"] as Double?, 8)
        XCTAssertEqual(row?["sessionRPEOrigin"] as String?, SessionRPEOrigin.legacyUnknown.rawValue)
    }

    func testV67AddsCanonicalIdentityWithoutRewritingExistingDefinitions() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v66-strength-workout-summary-pauses")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingExerciseDefinition
                  (id, title, mode, primaryMuscleId, secondaryMuscleIdsJSON, equipmentIdsJSON,
                   instructionsJSON, isUnilateral, source, sourceId, mediaId, updatedAtTs)
                VALUES ('legacy:row', 'Row', 'weight_reps', 'upper_back', '[]', '["barbell"]',
                        '[]', 0, 'noop', NULL, NULL, 10)
                """)
        }

        try migrator.migrate(queue)

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM trainingExerciseDefinition WHERE id = 'legacy:row'")
        }
        XCTAssertEqual(row?["title"] as String?, "Row")
        XCTAssertNil(row?["canonicalId"] as String?)
        XCTAssertNil(row?["aliasesJSON"] as String?)
        XCTAssertNil(row?["contentVersion"] as Int?)
        XCTAssertNil(row?["loadSemantics"] as String?)
    }

    func testCanonicalIdentityRoundTripsAndALegacyRowReadsAsItsDerivedMeaning() async throws {
        let store = try await WhoopStore.inMemory()
        let canonical = TrainingExercise(
            id: "noop:press", title: "Overhead Press", mode: .weightReps, primaryMuscleId: "front_delts",
            equipmentIds: ["barbell"], source: .noop, canonicalId: "overhead-press",
            aliases: ["military press"], contentVersion: 2, attribution: "NOOP",
            loadSemantics: .totalExternalLoad)
        let plain = TrainingExercise(id: "user:curl", title: "Curl", mode: .weightReps,
                                     primaryMuscleId: "biceps", equipmentIds: ["dumbbell"],
                                     source: .user)

        try await store.upsertTrainingExercises([canonical, plain], nowTs: 20)
        let stored = try await store.trainingExercises()

        XCTAssertEqual(stored.first { $0.id == canonical.id }, canonical)
        let readBack = try XCTUnwrap(stored.first { $0.id == plain.id })
        XCTAssertEqual(readBack, plain)
        XCTAssertNil(readBack.canonicalId)
        XCTAssertEqual(readBack.contentVersion, 0)
        XCTAssertEqual(readBack.effectiveLoadSemantics, .perImplement)
    }

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
                .init(targetWeightKg: 80, repsMin: 6, repsMax: 8),
                .init(intensifier: .restPause, targetWeightKg: 80, repsMin: 3,
                      intensifierConfiguration: .init(segmentCount: 2, restPauseSeconds: 20))
            ], restSeconds: 180, warmupRestSeconds: 45, supersetId: superset,
                  progression: .init(policy: .doubleProgression), barWeightKg: 20,
                  loadSemantics: .totalExternalLoad)
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

    func testCompleteWorkoutDomainRoundTripsNormalizedStorage() async throws {
        let store = try await WhoopStore.inMemory()
        let originId = UUID()
        let clusterId = UUID()
        var origin = NativeWorkoutSet(id: originId, index: 0, weightKg: 32,
                                      leftReps: 10, rightReps: 9,
                                      targetDurationS: 60, durationS: 54,
                                      clusterId: clusterId)
        origin.isCompleted = true
        var segment = NativeWorkoutSet(index: 1, intensifier: .restPause, weightKg: 32,
                                       leftReps: 4, rightReps: 3,
                                       clusterId: clusterId, parentSetId: originId, segmentIndex: 1)
        segment.isCompleted = true
        let sessionId = UUID()
        let workout = NativeWorkout(
            id: UUID(), title: "Unilateral", startedAt: 100, endedAt: 500,
            plannedDay: "1970-01-01", routineIds: [],
            exercises: [.init(exerciseId: "split-squat", sets: [origin, segment],
                              restSeconds: 120, warmupRestSeconds: 30,
                              equipmentSnapshot: .init(equipmentIds: ["dumbbell"],
                                                       loadSemantics: .perImplement,
                                                       implementCount: 2))],
            tracker: .init(trackerId: "strap-a", manufacturer: "NOOP", model: "Band",
                           confidence: .userSelected, capabilities: [.heartRate]),
            sessionRPE: 8, sessionRPEOrigin: .later,
            trainingSessionId: sessionId, physiologyProvider: .noopBand,
            physiologyComponentKey: "manual|100|strength training",
            hrCoverage: 0.82, lifecycleVersion: 2,
            pauseIntervals: [.init(startedAtTs: 200, endedAtTs: 240)])

        try await store.completeNativeWorkout(workout)
        let stored = try await store.nativeWorkouts(from: 0, to: 1_000)
        XCTAssertEqual(stored, [workout])
    }

    /// Discarding is the wearer saying the session did not happen: the draft goes, history gains
    /// nothing, and a draft started afterwards is left alone.
    func testDiscardingADraftDeletesOnlyThatDraftAndWritesNoHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let abandoned = WorkoutDraft(title: "Abandoned", startedAt: 100, plannedDay: "2026-09-13")
        try await store.saveWorkoutDraft(abandoned)

        let deleted = try await store.deleteWorkoutDraft(id: abandoned.id)
        XCTAssertTrue(deleted)
        let afterDiscard = try await store.workoutDraft()
        XCTAssertNil(afterDiscard)
        let history = try await store.nativeWorkouts(from: 0, to: 1_000)
        XCTAssertEqual(history, [])

        // Deleting it again is not an error, it is simply nothing left to delete.
        let repeated = try await store.deleteWorkoutDraft(id: abandoned.id)
        XCTAssertFalse(repeated)

        // A draft started after the discard survives a stale delete for the abandoned one.
        let current = WorkoutDraft(title: "Current", startedAt: 300, plannedDay: "2026-09-14")
        try await store.saveWorkoutDraft(current)
        _ = try await store.deleteWorkoutDraft(id: abandoned.id)
        let survivor = try await store.workoutDraft()
        XCTAssertEqual(survivor?.id, current.id)
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

    func testNativeWorkoutHistorySupportsStablePagination() async throws {
        let store = try await WhoopStore.inMemory()
        for (index, start) in [100, 200, 300].enumerated() {
            let workout = NativeWorkout(
                id: UUID(), title: "Workout \(index)", startedAt: start, endedAt: start + 60,
                plannedDay: "1970-01-01", routineIds: [], exercises: [], tracker: nil)
            try await store.completeNativeWorkout(workout)
        }

        let first = try await store.nativeWorkouts(from: 0, to: 1_000, limit: 1, offset: 0)
        let second = try await store.nativeWorkouts(from: 0, to: 1_000, limit: 1, offset: 1)
        let third = try await store.nativeWorkouts(from: 0, to: 1_000, limit: 1, offset: 2)

        XCTAssertEqual(first.map(\.startedAt), [300])
        XCTAssertEqual(second.map(\.startedAt), [200])
        XCTAssertEqual(third.map(\.startedAt), [100])
        XCTAssertEqual(Set((first + second + third).map(\.id)).count, 3)
    }
}
