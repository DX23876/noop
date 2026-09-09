import XCTest
import GRDB
@testable import WhoopStore

/// Pins the Hevy lane's storage contract (v54).
///
/// The properties that matter here are all about a sync running MORE THAN ONCE. Hevy's incremental
/// feed can re-deliver a workout the store already has — a re-run after a failed page, a workout
/// edited twice, a resumed backfill — so every write has to converge on the same rows rather than
/// accumulate. The bug this file exists to prevent is the quiet one: a set that stays behind after an
/// edit removed it, still counting toward weekly volume with nothing on screen to explain it.
final class HevyStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func set(_ index: Int, _ type: HevySetType = .normal,
                     kg: Double? = 100, reps: Int? = 5, rpe: Double? = nil) -> HevySet {
        HevySet(index: index, type: type, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
    }

    private func workout(id: String = "w1", startTs: Int = 1_700_000_000,
                         updatedAtTs: Int = 1_700_000_100,
                         exercises: [HevyExercise]? = nil) -> HevyWorkout {
        HevyWorkout(
            id: id, title: "Push Day", routineId: "r1", notes: nil,
            startTs: startTs, endTs: startTs + 3600,
            updatedAtTs: updatedAtTs, createdAtTs: startTs,
            exercises: exercises ?? [
                HevyExercise(index: 0, title: "Bench Press (Barbell)", templateId: "T1",
                             supersetId: nil, notes: nil,
                             sets: [set(0, .warmup, kg: 40, reps: 10), set(1), set(2)]),
            ])
    }

    // MARK: - Schema

    func testV54CreatesTheStrengthTables() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["hevyWorkout", "hevyExercise", "hevySet", "hevyExerciseTemplate", "hevyRoutine"] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
        let setPK = try await store.primaryKeyColumns("hevySet")
        XCTAssertEqual(setPK, ["workoutId", "exerciseIdx", "idx"])
    }

    // MARK: - Round trip

    func testAWorkoutRoundTripsWithItsExercisesAndSets() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyWorkouts([workout()])

        let read = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertEqual(read.count, 1)
        let w = try XCTUnwrap(read.first)
        XCTAssertEqual(w.id, "w1")
        XCTAssertEqual(w.exercises.count, 1)
        XCTAssertEqual(w.exercises[0].sets.count, 3)
        // Order is load-bearing: set 1 of an exercise is not interchangeable with set 3.
        XCTAssertEqual(w.exercises[0].sets.map(\.index), [0, 1, 2])
        XCTAssertEqual(w.exercises[0].sets[0].type, .warmup)
        XCTAssertEqual(w.exercises[0].workingSets.count, 2, "the warmup must not count as work")
    }

    // MARK: - Idempotence, and the edit that REMOVES something

    /// THE re-sync property. The same workout delivered twice leaves one workout with one set of sets.
    func testResyncingTheSameWorkoutDoesNotDuplicateAnything() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyWorkouts([workout()])
        try await store.upsertHevyWorkouts([workout()])

        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 1)
        let rows = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        let w = try XCTUnwrap(rows.first)
        XCTAssertEqual(w.exercises.count, 1)
        XCTAssertEqual(w.exercises[0].sets.count, 3)
    }

    /// The one an upsert alone would get wrong. Editing a workout in Hevy to DROP a set has no upsert
    /// that removes the stale row — only rewriting the children does. A leftover set is invisible in
    /// the UI (the session still looks right) and permanently wrong in the volume totals.
    func testAnEditThatRemovesASetActuallyRemovesIt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyWorkouts([workout()])

        let trimmed = workout(exercises: [
            HevyExercise(index: 0, title: "Bench Press (Barbell)", templateId: "T1",
                         supersetId: nil, notes: nil,
                         sets: [set(0, .warmup, kg: 40, reps: 10), set(1)]),
        ])
        try await store.upsertHevyWorkouts([trimmed])

        let rows = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        let w = try XCTUnwrap(rows.first)
        XCTAssertEqual(w.exercises[0].sets.count, 2, "the dropped set is still in the database")
    }

    /// Same rule one level up: an exercise removed from the session must not survive as orphan sets.
    func testAnEditThatRemovesAnExerciseRemovesItsSets() async throws {
        let store = try await WhoopStore.inMemory()
        let two = workout(exercises: [
            HevyExercise(index: 0, title: "Bench Press (Barbell)", templateId: "T1",
                         supersetId: nil, notes: nil, sets: [set(0), set(1)]),
            HevyExercise(index: 1, title: "Incline Press (Dumbbell)", templateId: "T2",
                         supersetId: nil, notes: nil, sets: [set(0), set(1)]),
        ])
        try await store.upsertHevyWorkouts([two])
        try await store.upsertHevyWorkouts([workout()])   // back to one exercise

        let rows = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        let w = try XCTUnwrap(rows.first)
        XCTAssertEqual(w.exercises.count, 1)
        XCTAssertEqual(w.exercises.flatMap(\.sets).count, 3)
    }

    // MARK: - Deletes

    /// A `deleted` event has to take the sets with it. The cascade is declared in SQL precisely so a
    /// future delete path cannot forget one of the two tables.
    func testDeletingAWorkoutCascadesToExercisesAndSets() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyWorkouts([workout()])
        let touched = try await store.deleteHevyWorkouts(ids: ["w1"])

        XCTAssertEqual(touched, [1_700_000_000], "the deleted day must be reported for invalidation")
        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 0)
        let remaining = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertTrue(remaining.isEmpty)
        let orphans = try await store.countRowsForTest("hevySet")
        XCTAssertEqual(orphans, 0, "sets outlived their workout")
    }

    /// Deleting something that was never there changes nothing and — importantly — reports nothing,
    /// so a redundant delete event cannot trigger a day's re-derivation for no reason.
    func testDeletingAnUnknownWorkoutReportsNoAffectedDay() async throws {
        let store = try await WhoopStore.inMemory()
        let touched = try await store.deleteHevyWorkouts(ids: ["never-existed"])
        XCTAssertTrue(touched.isEmpty)
    }

    // MARK: - The incremental cursor

    /// The cursor is derived from the DATA, not kept as a separate counter. That is what stops an
    /// interrupted sync from leaving the cursor ahead of what was actually written — the failure where
    /// a run dies mid-page and every later run skips the gap forever.
    func testTheCursorIsTheNewestStoredUpdateAndNilWhenEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let empty = try await store.hevyNewestUpdatedAt()
        XCTAssertNil(empty)

        try await store.upsertHevyWorkouts([
            workout(id: "a", startTs: 1_700_000_000, updatedAtTs: 1_700_000_100),
            workout(id: "b", startTs: 1_700_100_000, updatedAtTs: 1_700_100_500),
        ])
        let cursor = try await store.hevyNewestUpdatedAt()
        XCTAssertEqual(cursor, 1_700_100_500)
    }

    /// The upsert reports the day of every workout it wrote, so the caller can invalidate exactly
    /// those days instead of the whole window.
    func testUpsertReportsOnlyTheDaysItTouched() async throws {
        let store = try await WhoopStore.inMemory()
        let touched = try await store.upsertHevyWorkouts([
            workout(id: "a", startTs: 1_700_000_000),
            workout(id: "b", startTs: 1_700_200_000),
        ])
        XCTAssertEqual(touched.sorted(), [1_700_000_000, 1_700_200_000])
    }

    // MARK: - The catalogue

    func testExerciseTemplatesRoundTripIncludingSecondaryGroups() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyExerciseTemplates([
            HevyExerciseTemplate(id: "T1", title: "Bench Press (Barbell)", type: "weight_reps",
                                 primaryMuscleGroup: .chest,
                                 secondaryMuscleGroups: [.triceps, .shoulders],
                                 equipment: .barbell, isCustom: false),
        ])
        let catalogue = try await store.hevyExerciseTemplates()
        let t = try XCTUnwrap(catalogue["T1"])
        XCTAssertEqual(t.primaryMuscleGroup, .chest)
        XCTAssertEqual(t.secondaryMuscleGroups, [.triceps, .shoulders])
        XCTAssertEqual(t.equipment, .barbell)
        XCTAssertTrue(t.isWeightAndReps)
    }

    /// An unknown enum value from a changed API decodes to `.other` rather than losing the row. Hevy's
    /// own docs warn the schema may change; a strict decode would turn that into a failed sync.
    func testUnknownEnumValuesDecodeToOtherRatherThanFailing() async throws {
        XCTAssertEqual(HevyMuscleGroup.parse("some_new_group"), .other)
        XCTAssertEqual(HevyEquipment.parse("hydraulic_press"), .other)
        XCTAssertEqual(HevySetType.parse("myo_rep"), .other)
        XCTAssertTrue(HevySetType.parse("myo_rep").countsAsWork,
                      "an unrecognised set type is far likelier to be new WORK than a warmup")
    }

    // MARK: - Routines

    /// The verbatim server document survives the round trip. Without it, editing a routine through
    /// Hevy's full-replace `PUT` would silently drop every field this build does not model.
    func testRoutineKeepsItsVerbatimServerDocument() async throws {
        let store = try await WhoopStore.inMemory()
        let raw = #"{"id":"r1","title":"Push","some_future_field":42}"#
        try await store.upsertHevyRoutines([
            HevyRoutine(id: "r1", title: "Push", folderId: nil, notes: nil,
                        updatedAtTs: 1_700_000_000, exercises: [], rawJSON: raw),
        ])
        let routines = try await store.hevyRoutines()
        let read = try XCTUnwrap(routines.first)
        XCTAssertEqual(read.rawJSON, raw)
    }

    // MARK: - Forget everything

    func testDisconnectRemovesEveryTrace() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertHevyWorkouts([workout()])
        try await store.upsertHevyExerciseTemplates([
            HevyExerciseTemplate(id: "T1", title: "Bench", type: "weight_reps",
                                 primaryMuscleGroup: .chest, secondaryMuscleGroups: [],
                                 equipment: .barbell, isCustom: false),
        ])
        try await store.upsertHevyRoutines([
            HevyRoutine(id: "r1", title: "Push", folderId: nil, notes: nil,
                        updatedAtTs: 1, exercises: [], rawJSON: "{}"),
        ])

        try await store.deleteAllHevyData()

        let count = try await store.hevyWorkoutCount()
        let sets = try await store.countRowsForTest("hevySet")
        let exercises = try await store.countRowsForTest("hevyExercise")
        let templates = try await store.hevyExerciseTemplates()
        let routines = try await store.hevyRoutines()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(sets, 0)
        XCTAssertEqual(exercises, 0)
        XCTAssertTrue(templates.isEmpty)
        XCTAssertTrue(routines.isEmpty)
    }

    func testOfflineStrengthSurvivesDisconnectAndDoesNotAdvanceAPICursor() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = HevyWorkout(id: "hevy_csv:1", title: "Imported", routineId: nil, notes: nil,
                                   startTs: 1_700_000_000, endTs: 1_700_003_600,
                                   updatedAtTs: 1_900_000_000, createdAtTs: 1_700_000_000,
                                   exercises: workout().exercises, source: .hevyCSV)
        try await store.upsertStrengthWorkouts([imported])
        let cursor = try await store.hevyNewestUpdatedAt()
        let beforeDisconnect = try await store.strengthWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertNil(cursor)
        XCTAssertEqual(beforeDisconnect.count, 1)

        try await store.deleteAllHevyData()

        let afterDisconnect = try await store.strengthWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertEqual(afterDisconnect.first?.source, .hevyCSV)
    }

    func testLocalExerciseMappingAttributesAnImportedExercise() async throws {
        let store = try await WhoopStore.inMemory()
        let exercise = HevyExercise(index: 0, title: "Mystery Press", templateId: nil,
                                    supersetId: nil, notes: nil, sets: [set(0)])
        let imported = HevyWorkout(id: "hevy_csv:2", title: "Imported", routineId: nil, notes: nil,
                                   startTs: 1_700_000_000, endTs: 1_700_003_600,
                                   updatedAtTs: 1_700_000_000, createdAtTs: 1_700_000_000,
                                   exercises: [exercise], source: .hevyCSV)
        try await store.upsertStrengthWorkouts([imported])
        try await store.upsertStrengthExerciseMapping(StrengthExerciseMapping(
            normalizedTitle: "mystery press", displayTitle: "Mystery Press",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps]))

        let read = try await store.strengthWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertEqual(read.first?.exercises.first?.templateId, "local:mystery press")
        let templates = try await store.strengthExerciseTemplates()
        XCTAssertEqual(templates["local:mystery press"]?.primaryMuscleGroup, .chest)
    }
}

extension WhoopStore {
    /// Row count for a table, for tests that need to prove a CASCADE actually fired — the public read
    /// API deliberately cannot see an orphan row, which is exactly what makes one dangerous.
    func countRowsForTest(_ table: String) throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }
}
