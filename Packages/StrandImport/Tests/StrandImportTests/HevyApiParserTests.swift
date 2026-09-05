import XCTest
import WhoopStore
@testable import StrandImport

/// Pins the Hevy API parser against the shapes the real endpoints return.
///
/// Every fixture here is the documented response shape from `api.hevyapp.com/docs`, not an invented
/// one. The tests that matter most are the TOLERANCE cases: Hevy's own documentation warns it may
/// "completely change the structure or abandon the project entirely", so the parser's job is to keep
/// returning what it can read and to COUNT what it could not — a background sync that fails wholesale
/// on one renamed field shows the user stale data with no cause they can see.
final class HevyApiParserTests: XCTestCase {

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - A complete workout

    /// The documented shape, end to end: superset, warmup, RPE, and a bodyweight set.
    func testAFullWorkoutParsesWithSupersetsWarmupsAndRpe() {
        let doc = json("""
        {
          "id": "b459cba5-cd6d-463c-abd6-54f8eafcadcb",
          "title": "Morning Workout",
          "routine_id": "r-1",
          "description": "Felt strong",
          "start_time": "2026-09-01T17:00:00Z",
          "end_time": "2026-09-01T18:05:00Z",
          "updated_at": "2026-09-01T18:10:00Z",
          "created_at": "2026-09-01T17:00:00Z",
          "exercises": [
            { "index": 0, "title": "Bench Press (Barbell)", "exercise_template_id": "05293BCA",
              "superset_id": 0, "notes": "paused",
              "sets": [
                { "index": 0, "type": "warmup", "weight_kg": 40, "reps": 10 },
                { "index": 1, "type": "normal", "weight_kg": 100, "reps": 5, "rpe": 8.5 },
                { "index": 2, "type": "failure", "weight_kg": 100, "reps": 3, "rpe": 10 }
              ] },
            { "index": 1, "title": "Pull Up", "exercise_template_id": "AAAA1111",
              "superset_id": 0, "sets": [ { "index": 0, "type": "normal", "reps": 12 } ] }
          ]
        }
        """)
        let r = HevyApiParser.parseWorkouts([doc])
        XCTAssertEqual(r.skipped, 0)
        let w = try? XCTUnwrap(r.items.first)
        guard let w else { return XCTFail("no workout") }

        XCTAssertEqual(w.id, "b459cba5-cd6d-463c-abd6-54f8eafcadcb")
        XCTAssertEqual(w.notes, "Felt strong", "Hevy's `description` maps onto `notes`")
        XCTAssertEqual(w.durationS, 3900)
        XCTAssertEqual(w.updatedAtTs, 1_788_286_200)
        XCTAssertEqual(w.exercises.count, 2)
        XCTAssertEqual(w.exercises[0].supersetId, 0)
        XCTAssertEqual(w.exercises[1].supersetId, 0, "both halves of the superset carry the same id")
        XCTAssertEqual(w.exercises[0].sets.map(\.type), [.warmup, .normal, .failure])
        XCTAssertEqual(w.exercises[0].workingSets.count, 2, "the warmup is not work")
        XCTAssertEqual(w.exercises[0].sets[1].rpe, 8.5)

        // A bodyweight set: reps, no weight. Real work, and it must survive.
        let pullUp = w.exercises[1].sets[0]
        XCTAssertEqual(pullUp.reps, 12)
        XCTAssertNil(pullUp.weightKg)
        XCTAssertNil(pullUp.volumeLoadKg, "no weight means no volume to claim — nil, not zero")
    }

    // MARK: - What gets skipped, and what deliberately does not

    /// A workout with no id or no readable start cannot be stored (the id IS the primary key), so it
    /// is dropped and counted.
    func testAWorkoutWithoutAnIdOrStartIsSkippedAndCounted() {
        let noId = json(#"{"start_time":"2026-09-01T17:00:00Z"}"#)
        let noStart = json(#"{"id":"x"}"#)
        let r = HevyApiParser.parseWorkouts([noId, noStart])
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.skipped, 2)
    }

    /// A set that measures NOTHING is dropped: it cannot contribute to any figure, and keeping it
    /// would inflate the set counts weekly volume is built from. The workout itself survives.
    func testASetThatMeasuresNothingIsDroppedButTheWorkoutSurvives() {
        let doc = json("""
        { "id": "w", "start_time": "2026-09-01T17:00:00Z",
          "exercises": [ { "index": 0, "title": "Bench", "sets": [
              { "index": 0, "type": "normal" },
              { "index": 1, "type": "normal", "weight_kg": 60, "reps": 8 } ] } ] }
        """)
        let r = HevyApiParser.parseWorkouts([doc])
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.items[0].exercises[0].sets.count, 1)
    }

    /// An unknown set type keeps the set and counts it as WORK. Guessing that an unrecognised label
    /// means "not real work" would silently shrink a session; the only type that must not count is
    /// `warmup`, and that one is known.
    func testAnUnknownSetTypeIsKeptAndStillCountsAsWork() {
        let doc = json("""
        { "id": "w", "start_time": "2026-09-01T17:00:00Z",
          "exercises": [ { "index": 0, "title": "Bench",
            "sets": [ { "index": 0, "type": "myo_rep", "weight_kg": 60, "reps": 8 } ] } ] }
        """)
        let r = HevyApiParser.parseWorkouts([doc])
        XCTAssertEqual(r.skipped, 0)
        XCTAssertEqual(r.items[0].exercises[0].sets[0].type, .other)
        XCTAssertEqual(r.items[0].exercises[0].workingSets.count, 1)
    }

    /// An out-of-range RPE is dropped rather than stored. Hevy's scale is 6–10; a 95 is a unit mix-up
    /// or corruption, and it would poison every effort-vs-load comparison that reads it.
    func testAnImplausibleRpeIsDiscardedWhileTheSetIsKept() {
        let doc = json("""
        { "id": "w", "start_time": "2026-09-01T17:00:00Z",
          "exercises": [ { "index": 0, "title": "Bench", "sets": [
            { "index": 0, "type": "normal", "weight_kg": 60, "reps": 8, "rpe": 95 } ] } ] }
        """)
        let set = HevyApiParser.parseWorkouts([doc]).items[0].exercises[0].sets[0]
        XCTAssertNil(set.rpe)
        XCTAssertEqual(set.reps, 8, "the set itself is fine — only the impossible rating went")
    }

    /// A missing or inverted end time means "no measurable duration", not corruption: the sets are
    /// what matter and they are all still there.
    func testAMissingEndTimeLeavesTheSessionWithoutADurationRatherThanDroppingIt() {
        let doc = json("""
        { "id": "w", "start_time": "2026-09-01T17:00:00Z",
          "exercises": [ { "index": 0, "title": "Bench",
            "sets": [ { "index": 0, "type": "normal", "weight_kg": 60, "reps": 8 } ] } ] }
        """)
        let w = HevyApiParser.parseWorkouts([doc]).items[0]
        XCTAssertNil(w.durationS)
        XCTAssertEqual(w.endTs, w.startTs)
        XCTAssertEqual(w.exercises[0].sets.count, 1)
    }

    /// A missing `updated_at` falls back rather than parking the cursor at zero — which would make
    /// every later sync re-fetch the entire history.
    func testAMissingUpdatedAtFallsBackInsteadOfZeroingTheCursor() {
        let doc = json(#"{"id":"w","start_time":"2026-09-01T17:00:00Z","created_at":"2026-08-30T10:00:00Z"}"#)
        let w = HevyApiParser.parseWorkouts([doc]).items[0]
        XCTAssertEqual(w.updatedAtTs, 1_788_084_000, "falls back to created_at")
    }

    // MARK: - The incremental feed

    /// The mixed feed: updates and deletes in one page, resolved from the `oneOf` union.
    func testTheEventFeedResolvesUpdatesAndDeletes() {
        let docs = [
            json("""
            { "type": "updated", "workout": { "id": "w1", "title": "Push",
              "start_time": "2026-09-01T17:00:00Z", "updated_at": "2026-09-01T18:00:00Z" } }
            """),
            json(#"{"type":"deleted","id":"w2","deleted_at":"2026-09-02T09:00:00Z"}"#),
        ]
        let r = HevyApiParser.parseWorkoutEvents(docs)
        XCTAssertEqual(r.skipped, 0)
        XCTAssertEqual(r.items.count, 2)
        guard case .updated(let w) = r.items[0] else { return XCTFail("expected an update") }
        XCTAssertEqual(w.id, "w1")
        guard case .deleted(let id, let at) = r.items[1] else { return XCTFail("expected a delete") }
        XCTAssertEqual(id, "w2")
        XCTAssertEqual(at, 1_788_339_600)
    }

    /// A delete with no readable timestamp is still APPLIED — the workout is gone either way. It just
    /// contributes nothing to the cursor.
    func testADeleteWithoutATimestampIsStillApplied() {
        let r = HevyApiParser.parseWorkoutEvents([json(#"{"type":"deleted","id":"w9"}"#)])
        XCTAssertEqual(r.skipped, 0)
        guard case .deleted(let id, let at) = r.items.first else { return XCTFail("expected a delete") }
        XCTAssertEqual(id, "w9")
        XCTAssertEqual(at, 0)
    }

    /// An event verb this build does not know is counted, never guessed at. Applying an unknown verb
    /// to somebody's training history is exactly the wrong kind of confident.
    func testAnUnknownEventTypeIsCountedNotGuessedAt() {
        let r = HevyApiParser.parseWorkoutEvents([json(#"{"type":"archived","id":"w3"}"#)])
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.skipped, 1)
    }

    /// The cursor advances from whichever event is newest, whether it was an update or a delete.
    func testEventTimestampsDriveTheCursor() {
        let docs = [
            json("""
            { "type": "updated", "workout": { "id": "w1", "start_time": "2026-09-01T17:00:00Z",
              "updated_at": "2026-09-01T18:00:00Z" } }
            """),
            json(#"{"type":"deleted","id":"w2","deleted_at":"2026-09-03T09:00:00Z"}"#),
        ]
        let newest = HevyApiParser.parseWorkoutEvents(docs).items.map(\.timestamp).max()
        XCTAssertEqual(newest, 1_788_426_000)
    }

    // MARK: - The catalogue

    func testExerciseTemplatesParseWithBothMuscleGroupTiers() {
        let doc = json("""
        { "id": "05293BCA", "title": "Bench Press (Barbell)", "type": "weight_reps",
          "primary_muscle_group": "chest",
          "secondary_muscle_groups": ["triceps", "shoulders"],
          "equipment": "barbell", "is_custom": false }
        """)
        let r = HevyApiParser.parseExerciseTemplates([doc])
        XCTAssertEqual(r.skipped, 0)
        let t = r.items[0]
        XCTAssertEqual(t.primaryMuscleGroup, .chest)
        XCTAssertEqual(t.secondaryMuscleGroups, [.triceps, .shoulders])
        XCTAssertEqual(t.equipment, .barbell)
        XCTAssertTrue(t.isWeightAndReps)
    }

    /// A muscle group or equipment value Hevy adds later lands as `.other` instead of failing the
    /// whole catalogue sync.
    func testAnUnknownMuscleGroupDoesNotFailTheCatalogue() {
        let doc = json("""
        { "id": "X", "title": "New Movement", "type": "weight_reps",
          "primary_muscle_group": "some_new_group", "secondary_muscle_groups": ["also_new"],
          "equipment": "hydraulic_press", "is_custom": true }
        """)
        let t = HevyApiParser.parseExerciseTemplates([doc]).items[0]
        XCTAssertEqual(t.primaryMuscleGroup, .other)
        XCTAssertEqual(t.secondaryMuscleGroups, [.other])
        XCTAssertEqual(t.equipment, .other)
    }

    // MARK: - Routines

    /// The verbatim document survives. `PUT /v1/routines/{id}` is a FULL REPLACE, so a field this
    /// build does not model would be dropped on the first edit without this round trip.
    func testARoutineKeepsUnmodelledFieldsInItsRawDocument() {
        let doc = json("""
        { "id": "r1", "title": "Push Day", "folder_id": 42, "notes": "form first",
          "updated_at": "2026-09-01T18:00:00Z", "some_future_field": {"a": 1},
          "exercises": [ { "index": 0, "title": "Bench", "exercise_template_id": "T1",
            "sets": [ { "index": 0, "type": "normal", "weight_kg": 80, "reps": 8 } ] } ] }
        """)
        let r = HevyApiParser.parseRoutines([doc])
        XCTAssertEqual(r.skipped, 0)
        let routine = r.items[0]
        XCTAssertEqual(routine.folderId, 42)
        XCTAssertEqual(routine.exercises[0].sets[0].reps, 8)
        XCTAssertTrue(routine.rawJSON.contains("some_future_field"),
                      "an unmodelled field must survive, or the first edit silently deletes it")
    }

    // MARK: - Envelopes

    func testEnvelopeUnwrappingAndPageCount() {
        let data = Data(#"{"page":1,"page_count":7,"workouts":[{"id":"a"},{"id":"b"}]}"#.utf8)
        XCTAssertEqual(HevyApiParser.objects(data, key: "workouts").count, 2)
        XCTAssertEqual(HevyApiParser.pageCount(data), 7)
    }

    /// A malformed envelope stops paging rather than looping forever.
    func testAMalformedEnvelopeReportsOnePageAndNoObjects() {
        let data = Data("not json".utf8)
        XCTAssertTrue(HevyApiParser.objects(data, key: "workouts").isEmpty)
        XCTAssertEqual(HevyApiParser.pageCount(data), 1)
    }
}
