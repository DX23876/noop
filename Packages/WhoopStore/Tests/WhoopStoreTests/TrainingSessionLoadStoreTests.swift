import XCTest
import GRDB
@testable import WhoopStore

final class TrainingSessionLoadStoreTests: XCTestCase {
    private func row(_ id: String, start: Int = 1_000, trimp: Double? = 120, version: Int = 1,
                     fingerprint: String = "f1", computedAt: Int = 9_000) -> TrainingSessionLoadRow {
        TrainingSessionLoadRow(sessionId: id, method: "edwards-hrmax", methodVersion: version,
                               startTs: start, endTs: start + 3_600, trimp: trimp, effort: trimp.map { $0 / 10 },
                               hrSource: trimp == nil ? "none" : "noop_band", coveredMinutes: 58,
                               possibleMinutes: 60, hrmaxUsed: 188, restingHrUsed: nil,
                               inputFingerprint: fingerprint, computedAtTs: computedAt)
    }

    func testARowRoundTripsWithWhatItWasComputedFrom() async throws {
        let store = try await WhoopStore.inMemory()
        let priced = row("a")
        let unpriceable = row("b", start: 5_000, trimp: nil)
        try await store.upsertTrainingSessionLoads([priced, unpriceable])
        let byId = try await store.trainingSessionLoads(sessionIds: ["a", "b", "missing"],
                                                        method: "edwards-hrmax", methodVersion: 1)
        XCTAssertEqual(byId["a"], priced)
        XCTAssertEqual(byId["b"], unpriceable, "an unpriceable session is a known answer, not a missing row")
        XCTAssertNil(byId["missing"])
    }

    func testUpsertReplacesTheSameSessionAndMethodVersion() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTrainingSessionLoads([row("a", trimp: 100, fingerprint: "old")])
        try await store.upsertTrainingSessionLoads([row("a", trimp: 140, fingerprint: "new", computedAt: 10_000)])
        let stored = try await store.trainingSessionLoads(sessionIds: ["a"], method: "edwards-hrmax", methodVersion: 1)
        XCTAssertEqual(stored["a"]?.trimp, 140)
        XCTAssertEqual(stored["a"]?.inputFingerprint, "new")
    }

    /// A new method version sits beside the old one; neither read sees the other.
    func testMethodVersionsDoNotMix() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTrainingSessionLoads([row("a", trimp: 100, version: 1), row("a", trimp: 90, version: 2)])
        let v1 = try await store.trainingSessionLoads(sessionIds: ["a"], method: "edwards-hrmax", methodVersion: 1)
        let v2 = try await store.trainingSessionLoads(sessionIds: ["a"], method: "edwards-hrmax", methodVersion: 2)
        XCTAssertEqual(v1["a"]?.trimp, 100)
        XCTAssertEqual(v2["a"]?.trimp, 90)
    }

    func testARangeReadIsOrderedAndBounded() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertTrainingSessionLoads([row("late", start: 9_000), row("early", start: 1_000),
                                                    row("outside", start: 20_000)])
        let rows = try await store.trainingSessionLoads(from: 0, to: 10_000, method: "edwards-hrmax", methodVersion: 1)
        XCTAssertEqual(rows.map(\.sessionId), ["early", "late"])
    }

    /// More ids than SQLite binds in one statement are read in chunks.
    func testManyIdsAreReadInChunks() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = (0..<1_200).map { row("s\($0)", start: $0) }
        try await store.upsertTrainingSessionLoads(rows)
        let byId = try await store.trainingSessionLoads(sessionIds: rows.map(\.sessionId),
                                                        method: "edwards-hrmax", methodVersion: 1)
        XCTAssertEqual(byId.count, 1_200)
    }

    /// v70 is additive: a v69 database keeps its data and gains an empty table.
    func testV70AddsTheTableWithoutTouchingExistingRows() throws {
        let queue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(queue, upTo: "v69-lift-log")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO trainingSessionRating (id, sessionId, workoutStartTs, ratedAtTs, rpe, sport, source)
                VALUES ('r1', 's1', 100, 200, 7, 'Running', 'manual-session-rpe')
                """)
        }
        try WhoopStore.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trainingSessionRating"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trainingSessionLoad"), 0)
        }
    }
}
