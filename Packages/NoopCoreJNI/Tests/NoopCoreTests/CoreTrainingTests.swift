import XCTest
import NoopCore
import StrandCore
import StrandTraining
import WhoopStore

/// The Android training door (`CoreTraining`): the catalogue seeds into an empty store, a routine saved as JSON reads
/// back in the snapshot, a finished workout survives the JSON boundary, and seeding twice changes nothing.
final class CoreTrainingTests: XCTestCase {
    func testTheCatalogueSeedsAndARoutineRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("training-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("s.sqlite").path)
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])

        let first = await CoreTraining.snapshot(reader: reader, days: 30, weekStartsOn: .monday, dismissedWorkoutSpans: [])
        XCTAssertGreaterThan(first.exercises.count, 100, "the bundled catalogue is in the store")
        let seeded = try await store.trainingExerciseCount()
        await CoreTraining.prepare(store: store)
        let afterSecond = try await store.trainingExerciseCount()
        XCTAssertEqual(afterSecond, seeded)

        let routine = TrainingRoutine(title: "Push day")
        let json = String(data: try JSONEncoder().encode(routine), encoding: .utf8)!
        let saved = await CoreTraining.saveRoutine(store: store, json: json)
        XCTAssertTrue(saved)
        let second = await CoreTraining.snapshot(reader: reader, days: 30, weekStartsOn: .monday, dismissedWorkoutSpans: [])
        XCTAssertEqual(second.plan.routines.map(\.title), ["Push day"])
        XCTAssertEqual(second.routineMuscles[routine.id.uuidString], [:], "an empty routine involves no muscle")
        let deleted = await CoreTraining.deleteRoutine(store: store, id: routine.id.uuidString)
        XCTAssertTrue(deleted)

        let now = Int(Date().timeIntervalSince1970)
        let workout = NativeWorkout(id: UUID(), title: "Push day", startedAt: now - 3_600, endedAt: now,
                                    plannedDay: StoreReader.localDayKey(Date()), routineIds: [], exercises: [],
                                    tracker: nil)
        let workoutJSON = String(data: try JSONEncoder().encode(workout), encoding: .utf8)!
        let workoutSaved = await CoreTraining.finishWorkout(store: store, json: workoutJSON)
        XCTAssertTrue(workoutSaved)
        let finished = await CoreTraining.snapshot(reader: reader, days: 30, weekStartsOn: .monday,
                                                   dismissedWorkoutSpans: [])
        XCTAssertEqual(finished.workouts.map(\.id), [workout.id])
    }

    func testASessionStartsLogsASetAndFinishes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await WhoopStore(path: dir.appendingPathComponent("s.sqlite").path)
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])

        let started = await CoreTraining.startDraft(reader: reader, routineIds: [], dismissedWorkoutSpans: [])
        let draft = try XCTUnwrap(started)
        XCTAssertTrue(draft.exercises.isEmpty, "a freestyle session starts empty")
        let library = try await store.trainingExercises()
        let exerciseId = try XCTUnwrap(library.first?.id)
        let withExercise = await CoreTraining.changeDraft(store: store, args: ["change": "addExercise", "exerciseId": exerciseId])
        let exercise = try XCTUnwrap(withExercise?.exercises.first)
        let set = try XCTUnwrap(exercise.sets.first)
        let logged = await CoreTraining.changeDraft(store: store, args: [
            "change": "set", "exercise": exercise.id.uuidString, "set": set.id.uuidString,
            "weightKg": 80, "reps": 8, "done": true])
        XCTAssertEqual(logged?.exercises.first?.sets.first?.reps, 8)

        let finished = await CoreTraining.finishDraft(store: store, sessionRPE: 7)
        let workout = try XCTUnwrap(finished)
        XCTAssertEqual(workout.exercises.first?.sets.first?.weightKg, 80)
        XCTAssertEqual(workout.sessionRPE, 7)
        let draftAfter = try await store.workoutDraft()
        XCTAssertNil(draftAfter, "finishing removes the draft")

        // The hub reads what the session left: today in the year of activity, and its set in muscle balance when the
        // exercise has anatomy.
        let hub = await CoreTraining.snapshot(reader: reader, days: 400, weekStartsOn: .monday, dismissedWorkoutSpans: [])
        XCTAssertGreaterThanOrEqual(hub.activity.count, 364)
        XCTAssertEqual(hub.activity.last?.day, StoreReader.localDayKey(Date()))
        XCTAssertEqual(hub.strength.first?.exerciseCount, 1)
        XCTAssertEqual(hub.muscles.balanceCoverage.workingSets, 1)

        // Training Load reads the same session: one working set in the strength lane's seven days, eight weeks of
        // history, and no comparison yet with a single day of training.
        let load = await CoreTrainingLoad.read(reader: reader, maxHR: 190, sex: "male", dismissedWorkoutSpans: [])
        XCTAssertEqual(load.strength.sevenDayWorkingSets, 1)
        XCTAssertNil(load.strength.band)
        XCTAssertEqual(load.statement.kind, "noHistory")
        XCTAssertFalse(load.history.isEmpty)
        XCTAssertNotNil(String(data: try JSONEncoder().encode(load), encoding: .utf8))
    }
}
