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

    /// The step a host without a progress closure runs (Android, over the JSON bridge) does the same
    /// work as `fold`: the loop ends with every row under the one WHOOP and nothing left to do.
    func testFoldStepLoopEndsWithEverythingUnderTheOneWhoop() throws {
        let dbq = try makeDB()
        var moved = 0
        var steps = 0
        while true {
            let step = try WhoopRowFold.foldStep(writer: dbq, identityFrom: newStrap, chunkSize: 2)
            moved += step.moved
            steps += 1
            XCTAssertLessThan(steps, 50, "the step loop does not terminate")
            if step.done { break }
        }
        // 5 heart-rate rows, the computed day and the day-owner override; the clashing reading is moved
        // and then dropped in favour of the canonical one, so it counts here and not in the table below.
        XCTAssertEqual(moved, 7)
        try dbq.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM hrSample"), ["my-whoop"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample"), 6)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM dailyMetric"), ["my-whoop-noop"])
            XCTAssertFalse(try WhoopRowFold.isNeeded(in: db))
        }
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: dbq).all().map(\.id), ["my-whoop"])
        // Asking again is a no-op, as the Devices screen does after a resumed run.
        XCTAssertEqual(try WhoopRowFold.foldStep(writer: dbq, identityFrom: nil, chunkSize: 2),
                       WhoopRowFold.Step(moved: 0, done: true))
    }

    /// The offer the screens make: it names the strap that stays, and the id `bind` takes on.
    func testOfferNamesTheKeeperAndWhatBindTakesOn() throws {
        let dbq = try makeDB()
        let offer = try DeviceRegistryStore(dbQueue: dbq).whoopFoldOffer()
        XCTAssertTrue(offer.needed)
        // The old strap is the active one in this fixture, so it is the strap in use.
        XCTAssertEqual(offer.keeperId, oldStrap)
        XCTAssertEqual(offer.keeperName, "WHOOP 5.0 MG")
        XCTAssertEqual(offer.identityFrom, oldStrap)
        // With no WHOOP active the newest extra pairing stays, and the canonical row needs no identity.
        try dbq.write { db in try db.execute(sql: "UPDATE pairedDevice SET status = 'paired'") }
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: dbq).whoopFoldOffer().keeperId, newStrap)
        XCTAssertNil(WhoopRowFold.identity(of: PairedDevice(id: "my-whoop", brand: "WHOOP", model: "WHOOP",
                                                            sourceKind: .liveBLE, capabilities: [],
                                                            status: .active, addedAt: 1, lastSeenAt: 1)))
        // Nothing to fold, nothing to offer.
        try WhoopRowFold.fold(writer: dbq, identityFrom: nil)
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: dbq).whoopFoldOffer(), .none)
    }

    /// One WHOOP entry at pairing: the replacing strap takes over the canonical row, and a row that was
    /// already active only needs the live link re-pointed.
    func testTakeOverAdoptsTheStrapAndSaysWhenToRetarget() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)
        let first = try store.takeOverWhoopEntry(peripheralId: "PAIRED-1", model: "5.0 MG",
                                                 nickname: "  ", makeActive: true)
        XCTAssertEqual(first, WhoopRowFold.TakeOver(took: true, needsRetarget: false))
        var canonical = try XCTUnwrap(store.all().first { $0.id == WhoopRowFold.canonicalId })
        XCTAssertEqual(canonical.peripheralId, "PAIRED-1")
        XCTAssertEqual(canonical.model, "5.0 MG")
        XCTAssertNil(canonical.nickname)          // blank is no nickname, as renaming treats it
        XCTAssertEqual(canonical.status, .active)
        XCTAssertEqual(try store.all().filter { $0.status == .active }.count, 1)

        // The same entry, another strap: no active-device change fires, so the caller re-targets.
        let again = try store.takeOverWhoopEntry(peripheralId: "PAIRED-2", model: "4.0",
                                                 nickname: "Night strap", makeActive: true)
        XCTAssertEqual(again, WhoopRowFold.TakeOver(took: true, needsRetarget: true))
        canonical = try XCTUnwrap(store.all().first { $0.id == WhoopRowFold.canonicalId })
        XCTAssertEqual(canonical.peripheralId, "PAIRED-2")
        XCTAssertEqual(canonical.nickname, "Night strap")
    }

    /// An install whose WHOOP entry was forgotten has nothing to take over; the caller adds its own row.
    func testTakeOverRefusesWithoutTheOneWhoopEntry() throws {
        let dbq = try makeDB()
        try dbq.write { db in try db.execute(sql: "DELETE FROM pairedDevice WHERE id = 'my-whoop'") }
        let store = DeviceRegistryStore(dbQueue: dbq)
        XCTAssertEqual(try store.takeOverWhoopEntry(peripheralId: "PAIRED-1", model: "4.0",
                                                    nickname: nil, makeActive: true),
                       WhoopRowFold.TakeOver(took: false, needsRetarget: false))
        XCTAssertFalse(try store.all().contains { $0.id == WhoopRowFold.canonicalId })
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
