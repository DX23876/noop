import XCTest
import GRDB
import StrandTraining
@testable import WhoopStore

final class NativeCompletionRatingTests: XCTestCase {
    func testRatingFailureKeepsTheWholeDraftAndNoCompletedHistory() async throws {
        let store = try await WhoopStore.inMemory()
        var draft = WorkoutDraft(title: "Synthetic strength", startedAt: 100, plannedDay: "1970-01-01")
        var set = NativeWorkoutSet(index: 0, weightKg: 20, reps: 8); set.isCompleted = true
        draft.exercises = [.init(exerciseId: "squat", sets: [set])]
        try await store.saveWorkoutDraft(draft)
        let workout = try NativeWorkoutEngine.complete(draft: draft, endTs: 200, sessionRPE: 8)
        try await store.syncWrite { db in
            try db.execute(sql: "CREATE TRIGGER rejectRating BEFORE INSERT ON trainingSessionRating BEGIN SELECT RAISE(ABORT, 'forced failure'); END")
        }
        do { try await store.completeNativeWorkout(workout, ratedAtTs: 210); XCTFail("must roll back") }
        catch {}
        let stillDraft = try await store.workoutDraft()
        XCTAssertEqual(stillDraft, draft)
        let history = try await store.nativeWorkouts(from: 0, to: 1_000)
        XCTAssertTrue(history.isEmpty)
        try await store.syncWrite { db in try db.execute(sql: "DROP TRIGGER rejectRating") }
        try await store.completeNativeWorkout(workout, ratedAtTs: 210)
        let ratings = try await store.trainingSessionRatings(from: 0, to: 1_000)
        XCTAssertEqual(ratings.count, 1)
        XCTAssertEqual(ratings.first?.rpe, 8)
        XCTAssertEqual(ratings.first?.ratedAtTs, 210)
        let finished = try await store.nativeWorkouts(from: 0, to: 1_000)
        XCTAssertEqual(finished, [workout])
    }
}
