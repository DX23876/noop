import Foundation
import XCTest
import GRDB
@testable import WhoopStore

final class GoalPreferenceStateTests: XCTestCase {
    func testV79AddsSingletonWithoutRewritingSensorInputs() throws {
        let queue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v78-workout-elevation")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO device (id) VALUES ('owned-strap')")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('owned-strap', 123, 67)")
        }
        try WhoopStore.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try db.columns(in: "goalPreferenceState").map(\.name), ["id", "payload"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT bpm FROM hrSample WHERE ts = 123"), 67)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM goalPreferenceState"), 0)
        }
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: "INSERT INTO goalPreferenceState (id, payload) VALUES (2, ?)", arguments: [Data([1])])
        })
    }

    func testFailedDatabaseCommitKeepsPreviousImage() async throws {
        let store = try await WhoopStore.inMemory()
        let before = Data([1, 2, 3])
        let created = try await store.commitGoalPreferenceState(expected: nil, replacement: before)
        XCTAssertTrue(created)
        try await store.syncWrite { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_goal_change BEFORE UPDATE ON goalPreferenceState
                BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END
                """)
        }
        do {
            _ = try await store.commitGoalPreferenceState(expected: before, replacement: Data([4]))
            XCTFail("the database rejected the write")
        } catch {}
        let retained = try await store.goalPreferenceState()
        XCTAssertEqual(retained, before)
    }
}
