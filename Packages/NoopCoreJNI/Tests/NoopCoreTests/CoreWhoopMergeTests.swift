import XCTest
import GRDB
@testable import NoopCore
import WhoopStore

/// One WHOOP entry on Android: the Devices screen there asks the core for the offer, binds the keeper's
/// strap and then runs the fold a chunk at a time over this bridge, because a progress closure cannot
/// cross it. The loop must end with every reading under the one WHOOP id, nothing deleted, and a second
/// run must have nothing left to do.
final class CoreWhoopMergeTests: XCTestCase {
    private let oldStrap = "whoop-AA11"
    private let newStrap = "whoop-BB22"

    private func startSession() throws -> WhoopStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            ShadowSession.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(ShadowSession.start(path: dir.appendingPathComponent("core.sqlite").path,
                                           deviceId: "my-whoop"), 0)
        let store = try XCTUnwrap(ShadowSession.storeAndPath?.0)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: oldStrap, brand: "WHOOP", model: "5.0 MG", nickname: "Old strap",
                                      peripheralId: "AA:11", sourceKind: .liveBLE, capabilities: [.hr],
                                      status: .active, addedAt: 100, lastSeenAt: 200))
        try registry.add(PairedDevice(id: newStrap, brand: "WHOOP", model: "MG", nickname: "New strap",
                                      peripheralId: "BB:22", sourceKind: .liveBLE, capabilities: [.hr],
                                      status: .paired, addedAt: 300, lastSeenAt: 300))
        try store.registryWriter.write { db in
            // The seeded entry is active on a fresh store; the old strap is the one in hand here, and
            // exactly one row is active (invariant I1).
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE id = 'my-whoop'")
            for (id, ts) in [("my-whoop", 1), (oldStrap, 2), (oldStrap, 3), (oldStrap, 4),
                             (newStrap, 5), (newStrap, 6), (newStrap, 7)] {
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                               arguments: [id, ts, 60 + ts])
            }
        }
        return store
    }

    private func answer(_ op: String, _ json: String = "{}") async throws -> [String: Any] {
        let raw = await CoreCall.run(op, json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                             "\(op) answered \(raw)")
    }

    func testMergeStepsMoveEveryReadingOntoTheOneWhoopAndDeleteNothing() async throws {
        let store = try startSession()

        let offer = try await answer("device.whoopMergeOffer")
        XCTAssertEqual(offer["needed"] as? Bool, true)
        XCTAssertEqual(offer["keeperId"] as? String, oldStrap)      // the active strap stays connected
        XCTAssertEqual(offer["keeperName"] as? String, "Old strap")
        let identity = try XCTUnwrap(offer["identityFrom"] as? String)

        let bound = try await answer("device.whoopMergeBind", #"{"identityFrom":"\#(identity)"}"#)
        XCTAssertEqual(bound["ok"] as? Bool, true)
        // Bound before anything moved: the live strap already records under the surviving id.
        try await store.registryWriter.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT peripheralId FROM pairedDevice WHERE id = 'my-whoop'"),
                           "AA:11")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId = ?",
                                            arguments: [self.oldStrap]), 3)
        }

        var moved = 0
        var steps = 0
        while true {
            let step = try await answer("device.whoopMergeStep", #"{"identityFrom":"\#(identity)","chunk":2}"#)
            moved += try XCTUnwrap(step["moved"] as? Int)
            steps += 1
            XCTAssertLessThan(steps, 50, "the step loop does not terminate")
            if step["done"] as? Bool == true { break }
        }
        XCTAssertEqual(moved, 6)                                    // the six readings of the two extra ids
        XCTAssertGreaterThan(steps, 1, "a chunk of 2 cannot finish in one step")

        try await store.registryWriter.read { db in
            // Nothing deleted: the same seven readings, now under one id.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample"), 7)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM hrSample"), ["my-whoop"])
            XCTAssertFalse(try WhoopRowFold.isNeeded(in: db))
        }
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: store.registryWriter).all().map(\.id), ["my-whoop"])

        // A second run has nothing to do, and the screen stops offering.
        let again = try await answer("device.whoopMergeStep", #"{"chunk":2}"#)
        XCTAssertEqual(again["moved"] as? Int, 0)
        XCTAssertEqual(again["done"] as? Bool, true)
        let settled = try await answer("device.whoopMergeOffer")
        XCTAssertEqual(settled["needed"] as? Bool, false)
    }

    func testTakeOverPointsTheOneWhoopAtTheReplacingStrap() async throws {
        let store = try startSession()
        let took = try await answer("device.whoopTakeOver",
                                    #"{"peripheralId":"CC:33","model":"4.0","nickname":"Spare","makeActive":true}"#)
        XCTAssertEqual(took["took"] as? Bool, true)
        XCTAssertEqual(took["retarget"] as? Bool, false)            // another row was active, so the id changes
        let canonical = try XCTUnwrap(DeviceRegistryStore(dbQueue: store.registryWriter).all()
            .first { $0.id == WhoopRowFold.canonicalId })
        XCTAssertEqual(canonical.peripheralId, "CC:33")
        XCTAssertEqual(canonical.model, "4.0")
        XCTAssertEqual(canonical.nickname, "Spare")
        XCTAssertEqual(canonical.status, .active)

        // The same entry, another strap: nothing to activate, only the live link to re-point.
        let again = try await answer("device.whoopTakeOver",
                                     #"{"peripheralId":"DD:44","model":"4.0","makeActive":true}"#)
        XCTAssertEqual(again["retarget"] as? Bool, true)

        let refused = try await answer("device.whoopTakeOver", #"{"model":"4.0"}"#)
        XCTAssertEqual(refused["error"] as? String, "invalid")
    }
}
