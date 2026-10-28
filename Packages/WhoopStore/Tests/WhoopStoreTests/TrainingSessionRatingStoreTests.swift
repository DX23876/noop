import XCTest
import GRDB
@testable import WhoopStore

final class TrainingSessionRatingStoreTests: XCTestCase {
    func testRatingRoundTripPreservesWhenAndWhereItWasRecorded() async throws {
        let store = try await WhoopStore.inMemory()
        let rating = TrainingSessionRating(
            id: "session-rpe-100", sessionId: "session|abc", workoutStartTs: 100,
            ratedAtTs: 2_000, rpe: 8, sport: "Strength Training", source: "manual-session-rpe")
        try await store.upsertTrainingSessionRating(rating)

        let stored = try await store.trainingSessionRatings(from: 0, to: 500)
        XCTAssertEqual(stored, [rating])
    }

    func testLegacyLabBookRatingsMigrateWithoutInventingARatingTime() async throws {
        let queue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v61-native-training")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO labMarker
                  (id, deviceId, markerKey, category, day, takenAt, value, valueText, unit, source, note)
                VALUES ('session-rpe-100', 'training-load', 'session_rpe', 'trainingLoad',
                        '1970-01-01', 100, 7, 'session|legacy', 'RPE', 'manual-session-rpe', 'Run')
                """)
        }
        try WhoopStore.makeMigrator().migrate(queue)
        try await queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM trainingSessionRating"))
            XCTAssertEqual(row["workoutStartTs"] as Int, 100)
            XCTAssertNil(row["ratedAtTs"] as Int?)
            XCTAssertEqual(row["source"] as String, "manual-session-rpe")
        }
    }
    func testCanonicalEditsAndRemovalDoNotLeaveAnOlderRatingBehind() async throws {
        let store = try await WhoopStore.inMemory()
        for (id, start, source) in [("old-a", 100, "manual"), ("old-b", 101, "manual"), ("imported", 100, "imported")] {
            try await store.upsertTrainingSessionRating(.init(id: id, sessionId: "session-a", workoutStartTs: start,
                ratedAtTs: 200, rpe: 5, sport: "Run", source: source))
        }
        let edited = TrainingSessionRating(id: "new", sessionId: "session-a", workoutStartTs: 102,
            ratedAtTs: 300, rpe: 8, sport: "Run", source: "manual")
        let replaced = try await store.replaceTrainingSessionRating(edited)
        XCTAssertTrue(replaced)
        var rows = try await store.trainingSessionRatings(from: 0, to: 1_000)
        XCTAssertEqual(Set(rows.map(\.id)), ["new", "imported"])
        let removed = try await store.deleteTrainingSessionRatings(sessionId: "session-a", startTs: 102, source: "manual")
        XCTAssertTrue(removed)
        rows = try await store.trainingSessionRatings(from: 0, to: 1_000)
        XCTAssertEqual(rows.map(\.id), ["imported"])
    }

    func testAnIdCollisionDoesNotOverwriteAnotherCanonicalSession() async throws {
        let store = try await WhoopStore.inMemory()
        let previous = TrainingSessionRating(id: "shared-time", sessionId: "session-a", workoutStartTs: 100,
            ratedAtTs: 200, rpe: 5, sport: "Run", source: "manual")
        try await store.upsertTrainingSessionRating(previous)
        var different = previous; different.sessionId = "session-b"; different.rpe = 9
        let replaced = try await store.replaceTrainingSessionRating(different)
        XCTAssertFalse(replaced)
        let rows = try await store.trainingSessionRatings(from: 0, to: 1_000)
        XCTAssertEqual(rows, [previous])
    }

}
