import XCTest
@testable import NoopCore
import StrandCore
import StrandTraining
import WhoopStore

final class LoadedHevyImportTests: XCTestCase {
    func testPrescriptionsKeepTheirMeasurementKindsThroughSavedPlansAndCompletedLogs() async throws {
        let store = try await WhoopStore.inMemory()
        let legacy = TrainingExercise(id: "imported:hevy:HOLD", title: "Synthetic hold", mode: .weightReps,
            primaryMuscleId: "forearms", source: .imported, sourceId: "HOLD")
        try await store.upsertTrainingExercises([legacy], nowTs: 1)
        _ = try await store.upsertHevyExerciseTemplates([
            .init(id: "HOLD", title: "Synthetic hold", type: "weight_duration", primaryMuscleGroup: .forearms, secondaryMuscleGroups: [], equipment: .kettlebell, isCustom: true),
            .init(id: "CARRY", title: "Synthetic carry", type: "short_distance_weight", primaryMuscleGroup: .forearms, secondaryMuscleGroups: [], equipment: .kettlebell, isCustom: true),
            .init(id: "ASSIST", title: "Synthetic assisted movement", type: "bodyweight_assisted_reps", primaryMuscleGroup: .lats, secondaryMuscleGroups: [], equipment: .machine, isCustom: true),
            .init(id: "ADDED", title: "Synthetic bodyweight movement", type: "bodyweight_reps", primaryMuscleGroup: .lats, secondaryMuscleGroups: [], equipment: .none, isCustom: true)])
        let raw = #"{"id":"loaded-routine","title":"Synthetic loaded work","exercises":[{"index":0,"title":"Synthetic hold","exercise_template_id":"HOLD","sets":[{"type":"normal","weight_kg":20,"duration_seconds":45}]},{"index":1,"title":"Synthetic carry","exercise_template_id":"CARRY","sets":[{"type":"normal","weight_kg":30,"distance_meters":25}]},{"index":2,"title":"Synthetic assisted movement","exercise_template_id":"ASSIST","sets":[{"type":"normal","weight_kg":35,"reps":8}]},{"index":3,"title":"Synthetic bodyweight movement","exercise_template_id":"ADDED","sets":[{"type":"normal","weight_kg":15,"reps":10}]}]}"#
        _ = try await store.upsertHevyRoutines([.init(id: "loaded-routine", title: "Synthetic loaded work", folderId: nil,
            notes: nil, updatedAtTs: 1, exercises: [], rawJSON: raw)])
        let review = CoreHevyRoutines()
        let preview = try await review.preview(store: store)
        let accepted = try await review.accept(store: store, token: preview.token, ids: preview.routines.map(\.id))
        XCTAssertTrue(accepted)
        let plan = try await store.trainingPlan()
        let definitions = try await store.trainingExercises()
        let modes = Dictionary(definitions.map { ($0.id, $0.mode) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(modes[legacy.id], .weightReps, "importing a corrected source mode must not reinterpret old definitions")
        XCTAssertEqual(plan.routines[0].exercises.map { modes[$0.exerciseId]! }, [.weightDuration, .distanceWeight, .assistedBodyweight, .weightedBodyweight])
        let reader = StoreReader(store: store, activeDeviceId: "synthetic-strap", registeredWhoopIds: [])
        let started = await CoreTraining.startDraft(reader: reader, routineIds: plan.routines.map { $0.id.uuidString }, dismissedWorkoutSpans: [])
        let draft = try XCTUnwrap(started)
        XCTAssertEqual(draft.exercises[0].sets[0].weightKg, 20)
        XCTAssertEqual(draft.exercises[0].sets[0].durationS, 45)
        XCTAssertNil(draft.exercises[0].sets[0].reps)
        XCTAssertEqual(draft.exercises[1].sets[0].weightKg, 30)
        XCTAssertEqual(draft.exercises[1].sets[0].distanceM, 25)
        XCTAssertNil(draft.exercises[1].sets[0].reps)
        for exercise in draft.exercises {
            let set = exercise.sets[0]
            _ = await CoreTraining.changeDraft(store: store, args: ["change": "set", "exercise": exercise.id.uuidString, "set": set.id.uuidString, "done": true])
        }
        let finished = await CoreTraining.finishDraft(store: store, sessionRPE: nil)
        let completed = try XCTUnwrap(finished)
        XCTAssertEqual(completed.exercises[0].sets[0].durationS, 45)
        XCTAssertEqual(completed.exercises[1].sets[0].distanceM, 25)
        XCTAssertEqual(completed.exercises[0].sets[0].weightKg, 20)
        XCTAssertEqual(completed.exercises[1].sets[0].weightKg, 30)
        let reopened = try await store.nativeWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(reopened[0].exercises[0].sets[0].durationS, 45)
        XCTAssertEqual(reopened[0].exercises[1].sets[0].distanceM, 25)
        var loadedOnly = completed
        loadedOnly.exercises = Array(loadedOnly.exercises.prefix(2))
        XCTAssertEqual(NativeWorkoutEngine.summary(for: loadedOnly).loadedVolumeKg, 0,
            "weight multiplied by time or distance is not repetition volume")
        let detail = await CoreTrainingLibrary.detail(reader: reader, id: plan.routines[0].exercises[0].exerciseId, dismissedWorkouts: [])
        XCTAssertEqual(detail?.records.heaviestKg, 20)
        XCTAssertNil(detail?.records.estimatedOneRepMaxKg)
    }
}
