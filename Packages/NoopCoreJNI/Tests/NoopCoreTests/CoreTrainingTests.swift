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
}
