import XCTest
import StrandTraining
@testable import WhoopStore

final class TrainingExerciseAnatomyAliasStoreTests: XCTestCase {
    func testDetailedAliasRoundTripsAndUpsertReplacesCorrection() async throws {
        let store = try await WhoopStore.inMemory()
        let first = ExerciseAnatomy(id: "bench", title: "Bench Press", mode: .weightReps,
            movementPattern: .horizontalPush, primaryMuscleIds: ["chest"],
            secondaryMuscleIds: ["triceps"], stabilizerMuscleIds: ["serratus"],
            confidence: .userConfirmed)
        let alias = TrainingExerciseAnatomyAlias(
            key: "user|bench press", source: .imported, normalizedTitle: "bench press",
            anatomy: first, origin: "user", updatedAtTs: 10)
        try await store.upsertTrainingExerciseAnatomyAlias(alias)

        var rows = try await store.trainingExerciseAnatomyAliases()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].anatomy.primaryMuscleIds, ["chest"])
        XCTAssertEqual(rows[0].anatomy.stabilizerMuscleIds, ["serratus"])

        let corrected = ExerciseAnatomy(id: "bench", title: "Bench Press", mode: .weightReps,
            movementPattern: .horizontalPush, primaryMuscleIds: ["upper_chest"],
            confidence: .userConfirmed)
        try await store.upsertTrainingExerciseAnatomyAlias(.init(
            key: alias.key, source: .imported, normalizedTitle: alias.normalizedTitle,
            anatomy: corrected, origin: "user", updatedAtTs: 20))
        rows = try await store.trainingExerciseAnatomyAliases()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].anatomy.primaryMuscleIds, ["upper_chest"])
    }
}
