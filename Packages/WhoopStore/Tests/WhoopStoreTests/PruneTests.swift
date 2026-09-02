#if canImport(Compression)
// Every test here drives the zlib-backed raw outbox (pruneRaw / RawBatchMeta), which exists only
// where Compression does. Same treatment RawOutboxTests gets, for the same reason.
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class PruneTests: XCTestCase {
    private let frames: [[UInt8]] = [[0xAA, 0x00, 0x01, 0x02]]
    private func meta(_ id: String, capturedAt: Int, bytes: Int) -> RawBatchMeta {
        RawBatchMeta(batchId: id, deviceId: "dev1",
                     clockRef: ClockRef(device: 0, wall: 0),
                     capturedAt: capturedAt, startTs: 0, endTs: 0,
                     frameCount: frames.count, byteSize: bytes)
    }

    func testPrunesAgedSyncedBatches() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // synced long ago → pruned; synced recently → kept; unsynced → kept (under cap).
        try await store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try await store.enqueueRawBatch(meta("fresh", capturedAt: 20, bytes: 100), frames: frames)
        try await store.enqueueRawBatch(meta("unsynced", capturedAt: 30, bytes: 100), frames: frames)
        try await store.markRawBatchSynced(batchId: "aged", at: 1000)
        try await store.markRawBatchSynced(batchId: "fresh", at: 9500)

        let pruned = try await store.pruneRaw(now: 10000, keepWindowSeconds: 1000,
                                              maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 1)                                  // only "aged"
        let remaining = try await store.allBatchIdsForTest()
        XCTAssertEqual(remaining, ["fresh", "unsynced"])
    }

    func testEvictsOldestRawBeyondByteCap() async throws {
        // Policy 2 (#27): cap the total raw footprint, evicting the OLDEST batches. Decoded
        // streams persist before raw (E2 invariant), so dropping the oldest raw loses no metric.
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 500), frames: frames)
        try await store.enqueueRawBatch(meta("u2", capturedAt: 20, bytes: 500), frames: frames)
        try await store.enqueueRawBatch(meta("u3", capturedAt: 30, bytes: 500), frames: frames)
        // Cap 1000 < 1500 total: newest-first u3(500)+u2(500)=1000 fits, u1 tips over → evicted.
        let pruned = try await store.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 1000)
        XCTAssertEqual(pruned, 1)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids, ["u2", "u3"])                          // oldest (u1) dropped
    }

    func testEvictionAppliesToSyncedAndUnsyncedAlike() async throws {
        // The byte cap is a total-footprint bound: a freshly-synced batch still in the keep
        // window counts toward the cap, and the oldest raw (synced or not) is evicted first.
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("s1", capturedAt: 10, bytes: 800), frames: frames)
        try await store.enqueueRawBatch(meta("u2", capturedAt: 20, bytes: 800), frames: frames)
        try await store.markRawBatchSynced(batchId: "s1", at: 9000) // recent → survives Policy 1
        // Cap 1000 < 1600 total: u2(800) fits, s1 tips over → evicted by Policy 2.
        let pruned = try await store.pruneRaw(now: 9500, keepWindowSeconds: 1000, maxUnsyncedBytes: 1000)
        XCTAssertEqual(pruned, 1)
        let ids = try await store.allBatchIdsForTest()
        XCTAssertEqual(ids, ["u2"])
    }

    func testPruneNeverTouchesDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1, bpm: 60)]), deviceId: "dev1")
        try await store.enqueueRawBatch(meta("aged", capturedAt: 10, bytes: 100), frames: frames)
        try await store.markRawBatchSynced(batchId: "aged", at: 1)
        _ = try await store.pruneRaw(now: 100000, keepWindowSeconds: 10, maxUnsyncedBytes: 0)
        let rowCounts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(rowCounts.hr, 1)   // decoded untouched
    }

    func testNothingToPruneReturnsZero() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("u1", capturedAt: 10, bytes: 100), frames: frames)
        let pruned = try await store.pruneRaw(now: 100, keepWindowSeconds: 1000,
                                              maxUnsyncedBytes: 1_000_000)
        XCTAssertEqual(pruned, 0)
    }

}
#endif
