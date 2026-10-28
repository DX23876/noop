import XCTest
import Foundation
import StrandCore
import WhoopStore
import StrandTraining
@testable import NoopCore

final class CoreExerciseProviderTests: XCTestCase {
    func testReviewStoresOnlySelectedDefinitionsAndCannotBeReplayedAcrossStores() async throws {
        let first = try await WhoopStore.inMemory(), second = try await WhoopStore.inMemory()
        let rows = try ExerciseDBProviderClient.parse(Data(#"[{"id":"body","name":"Synthetic bodyweight","equipment":"body weight","target":"biceps"},{"id":"loaded","name":"Synthetic loaded","equipment":"dumbbell","target":"biceps"}]"#.utf8), attribution: ExerciseDBProviderClient.defaultAttribution)
        let legacy = TrainingExercise(id: "exercisedb:body", title: "Legacy bodyweight", mode: .weightReps,
            equipmentIds: ["body-weight"], source: .exerciseDB, sourceId: "body")
        try await first.upsertTrainingExercises([legacy], nowTs: 1)
        let reviewed = try ExerciseDBProviderClient.keepingMeasurementIdentity(rows, existing: [legacy])
        let provider = CoreExerciseProvider()
        let preview = await provider.prepare(store: first, exercises: reviewed)
        let before = try await first.trainingExercises()
        XCTAssertEqual(before, [legacy], "review must not store even the unselected definitions")
        let wrongStore = try await provider.accept(store: second, requested: preview.token, ids: [reviewed[0].id])
        XCTAssertFalse(wrongStore)
        let unknown = try await provider.accept(store: first, requested: preview.token, ids: ["unknown"])
        XCTAssertFalse(unknown)
        let saved = try await provider.accept(store: first, requested: preview.token, ids: [reviewed[0].id])
        XCTAssertTrue(saved)
        let stored = try await first.trainingExercises()
        XCTAssertEqual(stored, [legacy, reviewed[0]])
        XCTAssertEqual(stored.first { $0.id == legacy.id }, legacy)
        XCTAssertFalse(stored.contains { $0.id == rows[1].id })
        let repeated = try await provider.accept(store: first, requested: preview.token, ids: [reviewed[0].id])
        XCTAssertFalse(repeated)
        let fresh = await provider.prepare(store: first, exercises: rows)
        await provider.invalidate()
        let invalidated = try await provider.accept(store: first, requested: fresh.token, ids: [rows[1].id])
        XCTAssertFalse(invalidated)
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/training/exercise-provider.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        object["token"] = "synthetic-review"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
        XCTAssertEqual(object as NSDictionary, expected)
    }
}
