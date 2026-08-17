import XCTest
import WhoopProtocol
import GRDB
@testable import WhoopStore

/// The analyze gate's change-detector contract (`WhoopStore.sensorWriteSeq`).
///
/// This is the test the two previous detectors did not have, and both failed for want of it:
///   - `hrFingerprint(deviceId:)` was scoped to ONE device id while the write side followed the
///     registry, so it stopped moving while data kept arriving and the re-score it guards silently
///     stopped running.
///   - a plain row COUNT moves back to an earlier value when a delete is followed by a re-sync of the
///     same rows, which reads as "nothing changed" for the same silent result.
///
/// So the contract under test is exactly: **every sensor mutation moves the sequence, and the
/// sequence never moves backwards** — regardless of which device id the rows are written under.
final class SensorWriteSeqTests: XCTestCase {

    private func seq(_ store: WhoopStore) async throws -> Int {
        try await store.sensorWriteSeq()
    }

    func testStartsAtZeroBeforeAnySensorWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let s = try await seq(store)
        XCTAssertEqual(s, 0, "a fresh store has no sensor writes yet")
    }

    func testIngestAdvancesTheSequence() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let before = try await seq(store)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: "dev1")
        let after = try await seq(store)
        XCTAssertGreaterThan(after, before, "an offload must move the gate")
    }

    /// The #836/C1 regression, directly. `hrFingerprint` watched the canonical "my-whoop" while the
    /// strap wrote under `whoop-<uuid>`; the sequence must not care which id the rows arrive under.
    func testAdvancesForAnyDeviceIdNotJustTheCanonicalOne() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-535BB4BF", mac: nil, name: nil)
        let before = try await seq(store)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 500, bpm: 70)]),
                                   deviceId: "whoop-535BB4BF")
        let after = try await seq(store)
        XCTAssertGreaterThan(after, before,
                             "a strap writing under its own id must move the gate — this is C1")
    }

    /// A row COUNT returns to its old value here; a monotone sequence cannot. Delete N rows, re-insert
    /// the SAME N rows, and the detector must still read as "changed" relative to the start.
    func testDeleteThenResyncNeverReturnsToAnEarlierValue() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let rows = Streams(hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61)])
        _ = try await store.insert(rows, deviceId: "dev1")
        let afterFirstInsert = try await seq(store)

        try await store.deleteAllData(deviceId: "dev1")
        let afterDelete = try await seq(store)
        XCTAssertGreaterThan(afterDelete, afterFirstInsert, "a delete is a change")

        _ = try await store.insert(rows, deviceId: "dev1")
        let afterResync = try await seq(store)
        XCTAssertGreaterThan(afterResync, afterDelete, "the re-sync is a change too")
        // The row count is now identical to `afterFirstInsert`'s; the sequence must not be.
        XCTAssertGreaterThan(afterResync, afterFirstInsert,
                             "the detector must not read 'unchanged' after delete-then-resync")
    }

    func testTimestampHealAdvancesTheSequence() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // A far-future row the heal will purge.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 4_000_000_000, bpm: 60)]), deviceId: "dev1")
        let before = try await seq(store)
        let result = try await store.healImplausibleTimestamps()
        XCTAssertGreaterThan(result.rawRowsDeleted, 0, "the seeded future row should have been purged")
        let after = try await seq(store)
        XCTAssertGreaterThan(after, before,
                             "a heal invalidates the scores computed from the purged rows")
    }

    /// Monotone across a long mixed run: the sequence is non-decreasing at every step, and strictly
    /// greater end-to-end. This is the property the gate actually relies on.
    func testNeverDecreasesAcrossAMixedRun() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "a", mac: nil, name: nil)
        try await store.upsertDevice(id: "b", mac: nil, name: nil)
        var last = try await seq(store)
        let start = last

        for i in 0..<5 {
            _ = try await store.insert(Streams(hr: [HRSample(ts: 1000 + i, bpm: 60)]), deviceId: "a")
            let now = try await seq(store)
            XCTAssertGreaterThanOrEqual(now, last)
            last = now
        }
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 2000, rrMs: 800)]), deviceId: "b")
        var now = try await seq(store)
        XCTAssertGreaterThanOrEqual(now, last); last = now

        try await store.deleteAllData(deviceId: "a")
        now = try await seq(store)
        XCTAssertGreaterThanOrEqual(now, last); last = now

        XCTAssertGreaterThan(last, start)
    }

    /// The bump rides the mutation's OWN transaction, so a rolled-back write must not leave the
    /// sequence advanced past data that was never committed — otherwise the gate would skip a pass
    /// for rows that do not exist.
    func testBumpRollsBackWithItsTransaction() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await seq(store)
        struct Boom: Error {}
        await XCTAssertThrowsErrorAsync(try await store.failingSensorWriteForTest())
        let after = try await seq(store)
        XCTAssertEqual(after, before, "a rolled-back sensor write must not advance the gate")
    }
}

// MARK: - helpers

extension WhoopStore {
    /// Bump the sequence and then throw, so the enclosing transaction rolls back. Test-only.
    func failingSensorWriteForTest() async throws {
        struct Boom: Error {}
        try syncWrite { db in
            try WhoopStore.bumpSensorWriteSeq(db)
            throw Boom()
        }
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
