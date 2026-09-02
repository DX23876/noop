import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class StandardHRLifecyclePersistenceTests: XCTestCase {
    private final class CountingStore: StoreWriting {
        private(set) var offeredHRRows = 0
        private(set) var offeredRRRows = 0

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            offeredHRRows = streams.hr.count
            offeredRRRows = streams.rr.count
            // Deliberately differ from the offered counts: this is the store's conflict/dedup result.
            return (0, 1, 0, 0, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    func testBackgroundLifecycleFlushesSubThresholdStandardHRAndLogsStoreCounts() async {
        let store = CountingStore()
        var lines: [String] = []
        let collector = Collector(
            store: store,
            deviceId: "test-strap",
            log: { lines.append($0) },
            now: { 1_750_000_000 }
        )
        let manager = BLEManager(state: LiveState(), collector: collector)

        // Three accepted rows are intentionally below the 30-row cadence threshold. The invalid values
        // prove that the host-receipt line reports Collector's accepted/rejected split, not input totals.
        collector.ingestStandardHR(hr: 72, rr: [800, 100, 900], at: 1_750_000_000)
        XCTAssertEqual(store.offeredHRRows + store.offeredRRRows, 0)

        await manager.flushStandardHRForLifecycle(reason: .background)

        XCTAssertEqual(store.offeredHRRows, 1)
        XCTAssertEqual(store.offeredRRRows, 2)
        XCTAssertTrue(lines.contains(
            "standard-hr transport host-received hostUnixSec=1750000000"
                + " acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=1"
                + " pendingHRRows=1 pendingRRRows=2"
        ))
        XCTAssertTrue(lines.contains(
            "standard-hr transport flush-succeeded reason=background"
                + " offeredHRRows=1 offeredRRRows=2 insertedHRRows=0 insertedRRRows=1"
        ))
    }
}
