import XCTest
@testable import NoopCore
import StrandCore
import StrandTraining
import WhoopStore

final class CoreTrainingLibraryTests: XCTestCase {
    func testCustomCreationAndHistoryShareTheStoredExerciseAndCanonicalAnatomy() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let created = await CoreTrainingLibrary.create(store: store, title: "  Bench press  ", mode: "weight_reps",
            primary: "chest", equipment: " Olympic Barbell ", instruction: "  Keep a stable setup.  ", unilateral: false)
        let id = try XCTUnwrap(created)
        var catalog = try await CoreTrainingLibrary.catalog(store: store)
        XCTAssertGreaterThan(catalog.exercises.count, 150)
        let row = try XCTUnwrap(catalog.exercises.first { $0.id == id })
        XCTAssertEqual(row.title, "Bench press")
        XCTAssertEqual(row.equipment, ["barbell"])
        XCTAssertEqual(row.region, "chest")
        XCTAssertEqual(row.primary, ["chest"])
        XCTAssertTrue(row.matchingMuscles.contains("triceps"))
        XCTAssertEqual(row.source, "user")
        XCTAssertTrue(id.hasPrefix("user:"))
        let started = await CoreTraining.startDraft(reader: reader, routineIds: [], dismissedWorkoutSpans: [])
        XCTAssertNotNil(started)
        let draft = await CoreTraining.changeDraft(store: store, args: ["change": "addExercise", "exerciseId": id])
        let exercise = try XCTUnwrap(draft?.exercises.first)
        let set = try XCTUnwrap(exercise.sets.first)
        _ = await CoreTraining.changeDraft(store: store, args: ["change": "set", "exercise": exercise.id.uuidString,
            "set": set.id.uuidString, "weightKg": 80, "reps": 8, "done": true])
        let finished = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        XCTAssertNotNil(finished)
        let now = Int(Date().timeIntervalSince1970)
        let template = HevyExerciseTemplate(id: "import-bench", title: "Bench press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: true)
        _ = try await store.upsertHevyExerciseTemplates([template])
        let imported = HevyWorkout(id: "import-session", title: "Imported push", routineId: nil, notes: nil,
            startTs: now - 86_400, endTs: now - 82_800, updatedAtTs: now, createdAtTs: now,
            exercises: [HevyExercise(index: 0, title: "Bench press", templateId: template.id, supersetId: nil, notes: nil,
                sets: [HevySet(index: 0, type: .normal, weightKg: 85, reps: 5, distanceM: nil, durationS: nil,
                               rpe: 8, customMetric: nil)])], source: .hevyCSV)
        _ = try await store.upsertStrengthWorkouts([imported])
        let loaded = await CoreTrainingLibrary.detail(reader: reader, id: id, dismissedWorkouts: [], now: now)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.instructions, ["Keep a stable setup."])
        XCTAssertEqual(detail.records.sessions, 2, "native projection does not count the native log a second time")
        XCTAssertEqual(detail.records.heaviestKg, 85)
        XCTAssertNotNil(detail.records.estimatedOneRepMaxKg)
        XCTAssertEqual(detail.recent.map(\.isNative), [true, false])
        XCTAssertEqual(detail.recent.map(\.workingSets), [1, 1])
        XCTAssertFalse(detail.hasDraft)
        catalog.exercises = [row]
        try contract(catalog, name: "library")
        try contract(detail, name: "exercise-detail")
    }

    func testLibraryMeasurementKindsRoundTripThroughTheDraftDoor() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let durationID = await CoreTrainingLibrary.create(store: store, title: "Timed distance", mode: "distance_duration",
            primary: "lats", equipment: "", instruction: "", unilateral: false)
        let sidesID = await CoreTrainingLibrary.create(store: store, title: "Side repetitions", mode: "bodyweight_reps",
            primary: "chest", equipment: "", instruction: "", unilateral: true)
        _ = await CoreTraining.startDraft(reader: reader, routineIds: [], dismissedWorkoutSpans: [])
        let first = await CoreTraining.changeDraft(store: store, args: ["change": "addExercise", "exerciseId": try XCTUnwrap(durationID)])
        let timed = try XCTUnwrap(first?.exercises.first)
        let timedSet = try XCTUnwrap(timed.sets.first)
        _ = await CoreTraining.changeDraft(store: store, args: ["change": "set", "exercise": timed.id.uuidString,
            "set": timedSet.id.uuidString, "durationS": 75, "distanceM": 250.5, "done": true])
        let second = await CoreTraining.changeDraft(store: store, args: ["change": "addExercise", "exerciseId": try XCTUnwrap(sidesID)])
        let sides = try XCTUnwrap(second?.exercises.last)
        let sidesSet = try XCTUnwrap(sides.sets.first)
        let updated = await CoreTraining.changeDraft(store: store, args: ["change": "set", "exercise": sides.id.uuidString,
            "set": sidesSet.id.uuidString, "leftReps": 8, "rightReps": 6, "reps": NSNull(), "done": true])
        try contract(try XCTUnwrap(updated), name: "library-draft")
        let completed = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        let workout = try XCTUnwrap(completed)
        XCTAssertEqual(workout.exercises.count, 2)
        XCTAssertEqual(workout.exercises[0].sets.first?.durationS, 75)
        XCTAssertEqual(workout.exercises[0].sets.first?.distanceM, 250.5)
        XCTAssertEqual(workout.exercises[1].sets.first?.leftReps, 8)
        XCTAssertEqual(workout.exercises[1].sets.first?.rightReps, 6)
        XCTAssertNil(workout.exercises[1].sets.first?.reps)
    }

    func testInvalidCustomDefinitionsAreNotStored() async throws {
        let store = try await WhoopStore.inMemory()
        let blank = await CoreTrainingLibrary.create(store: store, title: " \n ", mode: "weight_reps",
            primary: "chest", equipment: "", instruction: "", unilateral: false)
        let mode = await CoreTrainingLibrary.create(store: store, title: "Press", mode: "unknown",
            primary: "chest", equipment: "", instruction: "", unilateral: false)
        let muscle = await CoreTrainingLibrary.create(store: store, title: "Press", mode: "weight_reps",
            primary: "unknown", equipment: "", instruction: "", unilateral: false)
        XCTAssertNil(blank); XCTAssertNil(mode); XCTAssertNil(muscle)
        let count = try await store.trainingExerciseCount()
        XCTAssertEqual(count, 0)
    }

    func testImportedCatalogNeedsItsOfflineStorageRightAndRetainsProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let exercise = TrainingExercise(id: "licensed:row", title: "Licensed row", mode: .weightReps,
            primaryMuscleId: "lats", source: .imported, attribution: "Test provider")
        var archive = ExerciseCatalogArchive(provider: "Test provider", rights: ExerciseContentRights(
            provider: "Test provider", licence: "Test permission", allowsOfflineCache: false,
            allowsRedistribution: false), exercises: [exercise])
        func json() throws -> String { String(data: try JSONEncoder().encode(archive), encoding: .utf8)! }
        let refused = await CoreTrainingLibrary.importCatalog(store: store, json: try json())
        XCTAssertNil(refused)
        let before = try await store.trainingExerciseCount()
        XCTAssertEqual(before, 0)
        archive.rights.allowsOfflineCache = true
        let imported = await CoreTrainingLibrary.importCatalog(store: store, json: try json())
        XCTAssertEqual(imported, 1)
        let stored = try await store.trainingExercises()
        XCTAssertEqual(stored.first?.attribution, "Test provider")
        XCTAssertEqual(stored.first?.source, .imported)
        archive.exercises = [TrainingExercise(id: "licensed:without-credit", title: "Other row", mode: .weightReps)]
        let withFallback = await CoreTrainingLibrary.importCatalog(store: store, json: try json())
        XCTAssertEqual(withFallback, 1)
        let again = try await store.trainingExercises()
        let fallback = try XCTUnwrap(again.first { $0.id == "licensed:without-credit" })
        XCTAssertEqual(fallback.attribution, "Test provider · Test permission")
        archive.exercises = [exercise, exercise]
        let duplicate = await CoreTrainingLibrary.importCatalog(store: store, json: try json())
        XCTAssertNil(duplicate, "duplicate identities are rejected before any definition is replaced")
        let countAfterDuplicate = try await store.trainingExerciseCount()
        XCTAssertEqual(countAfterDuplicate, again.count)
        let invalid = await CoreTrainingLibrary.importCatalog(store: store, json: "{}")
        XCTAssertNil(invalid)
    }

    func testReviewedMusclesDriveTheDisplayWhileStoredAliasesStillMatchFilters() {
        let exercise = TrainingExercise(id: "test", title: "Bench press", mode: .weightReps,
            primaryMuscleId: "quadriceps", equipmentIds: ["barbell"])
        let info = TrainingLibraryPreparation.Info(exercise)
        XCTAssertEqual(info.region, .chest)
        XCTAssertEqual(info.primary, ["chest"])
        XCTAssertTrue(info.matchesMuscle("quadriceps"), "a stored tag remains searchable")
        XCTAssertTrue(info.matchesMuscle("triceps"), "reviewed secondary anatomy is searchable too")
    }

    private func contract<T: Encodable>(_ value: T, name: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let path = root.appendingPathComponent("android/app/src/test/resources/training/\(name).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: path) }
        func shape(_ value: Any) -> String {
            if let o = value as? [String: Any] { return "{" + o.keys.sorted().map { "\($0):\(shape(o[$0]!))" }.joined(separator: ",") + "}" }
            if let a = value as? [Any] { return "[" + Set(a.map(shape)).sorted().joined(separator: ",") + "]" }
            return value is NSNumber ? "number" : "string"
        }
        let actual = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        XCTAssertEqual(shape(actual), shape(expected))
        if let modes = (actual as? [String: Any])?["modes"] as? [String] {
            XCTAssertEqual(modes, (expected as? [String: Any])?["modes"] as? [String],
                "a new core measurement kind requires a reviewed Android input-column contract")
        }
    }
}
