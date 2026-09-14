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
}
