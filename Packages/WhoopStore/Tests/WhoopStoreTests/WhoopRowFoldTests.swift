import XCTest
import GRDB
@testable import WhoopStore

/// The one-WHOOP fold: every other WHOOP id's rows move onto `my-whoop`, the extra registry rows go, and
/// nothing is lost. Fixture mirrors the 2026-10-03 install: the seeded row, an old 5.0 that carries most
/// of the history, a just-paired MG, and an old provisional id that only survives in data.
final class WhoopRowFoldTests: XCTestCase {
    private let oldStrap = "whoop-5AG00000001"
    private let newStrap = "whoop-5AM00000002"
    private let orphan = "whoop-00000000-0000-4000-8000-000000000501"

    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // seeds 'my-whoop' active
        let store = DeviceRegistryStore(dbQueue: dbq)
        try store.add(PairedDevice(id: oldStrap, brand: "WHOOP", model: "5.0 MG", nickname: "WHOOP 5.0 MG",
                                   peripheralId: "OLD-PERIPHERAL", sourceKind: .liveBLE, capabilities: [.hr],
                                   status: .active, addedAt: 100, lastSeenAt: 200))
        try store.add(PairedDevice(id: newStrap, brand: "WHOOP", model: "MG", nickname: "WHOOP 5.0 MG",
                                   peripheralId: "NEW-PERIPHERAL", sourceKind: .liveBLE, capabilities: [.hr, .steps],
                                   status: .archived, addedAt: 300, lastSeenAt: 300))
        try store.archive("my-whoop")
        try dbq.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE id = 'my-whoop'")
            for (id, ts, bpm) in [("my-whoop", 1, 60), ("my-whoop", 2, 61),
                                  (oldStrap, 2, 99), (oldStrap, 3, 62), (oldStrap, 4, 63),
                                  (newStrap, 5, 64), (orphan, 6, 65)] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                               arguments: [id, ts, bpm])
            }
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, strain) VALUES (?, '2026-10-02', 7.8)",
                           arguments: [oldStrap + "-noop"])
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, strain) VALUES ('my-whoop-noop', '2026-10-01', 6.0)")
            try db.execute(sql: "INSERT INTO dayOwnership (day, deviceId, locked) VALUES ('2026-10-02', ?, 0)",
                           arguments: [oldStrap])
            try db.execute(sql: "INSERT INTO scoreInputProvenance (deviceId, day, key, sourceId) VALUES ('my-whoop-noop', '2026-10-02', 'recovery', ?)",
                           arguments: [oldStrap])
        }
        return dbq
    }

    func testFindsRegistryAndDataOnlySources() throws {
        let dbq = try makeDB()
        let sources = try dbq.read { try WhoopRowFold.sourceIds(in: $0) }
        XCTAssertEqual(sources, [orphan, oldStrap, newStrap].sorted())
    }

    func testFoldMovesEveryRowOntoTheOneWhoopAndKeepsTheCanonicalRowOnAClash() throws {
        let dbq = try makeDB()
        let folded = try WhoopRowFold.fold(writer: dbq, identityFrom: newStrap, chunkSize: 2)
        XCTAssertEqual(Set(folded), [orphan, oldStrap, newStrap])

        try dbq.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT deviceId, ts, bpm FROM hrSample ORDER BY ts")
            XCTAssertEqual(rows.map { $0["deviceId"] as String }, Array(repeating: "my-whoop", count: 6))
            XCTAssertEqual(rows.map { $0["ts"] as Int }, [1, 2, 3, 4, 5, 6])
            // ts 2 existed under both ids: the canonical reading stays.
            XCTAssertEqual(rows[1]["bpm"] as Int, 61)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT deviceId FROM dailyMetric ORDER BY day"),
                           ["my-whoop-noop", "my-whoop-noop"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT deviceId FROM dayOwnership WHERE day = '2026-10-02'"),
                           "my-whoop")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sourceId FROM scoreInputProvenance"), "my-whoop")
        }
    }

    func testFoldLeavesOneActiveWhoopBoundToTheReplacingStrap() throws {
        let dbq = try makeDB()
        try WhoopRowFold.fold(writer: dbq, identityFrom: newStrap)
        let devices = try DeviceRegistryStore(dbQueue: dbq).all()
        XCTAssertEqual(devices.map(\.id), ["my-whoop"])
        let whoop = try XCTUnwrap(devices.first)
        XCTAssertEqual(whoop.status, .active)
        XCTAssertEqual(whoop.peripheralId, "NEW-PERIPHERAL")
        XCTAssertEqual(whoop.model, "MG")
        XCTAssertFalse(try dbq.read { try WhoopRowFold.isNeeded(in: $0) })
    }

    /// The live link is re-targeted after `bind`, before rows move; a resumed fold keeps that strap.
    func testBindPointsTheWhoopAtTheReplacingStrapAndSurvivesAResume() throws {
        let dbq = try makeDB()
        try WhoopRowFold.bind(writer: dbq, identityFrom: newStrap)
        var whoop = try XCTUnwrap(DeviceRegistryStore(dbQueue: dbq).all().first { $0.id == "my-whoop" })
        XCTAssertEqual(whoop.status, .active)
        XCTAssertEqual(whoop.peripheralId, "NEW-PERIPHERAL")
        // Rows have not moved yet.
        XCTAssertEqual(try dbq.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?",
                                                       arguments: [self.oldStrap]) }, 3)
        try WhoopRowFold.fold(writer: dbq, identityFrom: newStrap)
        whoop = try XCTUnwrap(DeviceRegistryStore(dbQueue: dbq).all().first { $0.id == "my-whoop" })
        XCTAssertEqual(whoop.peripheralId, "NEW-PERIPHERAL")
    }

    func testAnotherActiveSourceKeepsItsPlace() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        try store.add(PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", sourceKind: .liveAppleWatch,
                                   capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        try store.setActive("apple-health")
        try WhoopRowFold.fold(writer: dbq, identityFrom: newStrap)
        let statuses = Dictionary(uniqueKeysWithValues: try store.all().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses, ["apple-health": .active, "my-whoop": .paired])
    }

    /// An interrupted fold leaves every row under exactly one id; running it again finishes the job.
    func testFoldIsResumableAndIdempotent() throws {
        let dbq = try makeDB()
        // Simulate an interruption: part of the old strap already moved, its registry row still there.
        try dbq.write { db in
            try db.execute(sql: "UPDATE hrSample SET deviceId = 'my-whoop' WHERE deviceId = ? AND ts = 3",
                           arguments: [oldStrap])
        }
        try WhoopRowFold.fold(writer: dbq, identityFrom: newStrap)
        XCTAssertEqual(try WhoopRowFold.fold(writer: dbq, identityFrom: nil), [])
        let count = try dbq.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = 'my-whoop'")
        }
        XCTAssertEqual(count, 6)
    }
}
