import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class CollectorStandardHRContactTests: XCTestCase {
    private final class CaptureStore: StoreWriting {
        enum Failure: Error { case requested }

        var inserted: [Streams] = []
        var failNextInsert = false

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            if failNextInsert {
                failNextInsert = false
                throw Failure.requested
            }
            inserted.append(streams)
            return (streams.hr.count, streams.rr.count, streams.events.count,
                    streams.battery.count, streams.spo2.count, streams.skinTemp.count,
                    streams.resp.count, streams.gravity.count)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
    }

    func testContactOnlyBatchAutoFlushesAtThreshold() async {
        let store = CaptureStore()
        let collector = Collector(store: store, deviceId: "whoop-5")

        for ts in 1_750_000_000..<1_750_000_030 {
            collector.ingestStandardHR(
                hr: 0, rr: [], contact: .supportedNotDetected, at: ts
            )
        }
        for _ in 0..<10 where store.inserted.isEmpty { await Task.yield() }

        XCTAssertEqual(store.inserted.count, 1)
        guard let inserted = store.inserted.first else { return }
        XCTAssertTrue(inserted.hr.isEmpty)
        XCTAssertTrue(inserted.rr.isEmpty)
        XCTAssertEqual(inserted.events.count, 30)
    }

    func testWhoopStandardHRCollectorPersistsParsedContact() async {
        let store = CaptureStore()
        let collector = Collector(store: store, deviceId: "whoop-5")

        collector.ingestStandardHR(
            hr: 72, rr: [1_000], contact: .supportedNotDetected, at: 1_750_000_000
        )
        await collector.flushStandardHR()

        XCTAssertEqual(store.inserted, [
            StandardHRMapping.samples(
                fromHR: 72,
                rr: [1_000],
                contact: .supportedNotDetected,
                at: 1_750_000_000
            )
        ])
    }

    func testWhoopStandardHRCollectorRebuffersContactAfterInsertFailure() async {
        let store = CaptureStore()
        store.failNextInsert = true
        let collector = Collector(store: store, deviceId: "whoop-5")

        collector.ingestStandardHR(
            hr: 73, rr: [], contact: .supportedDetected, at: 1_750_000_001
        )
        await collector.flushStandardHR()
        XCTAssertTrue(store.inserted.isEmpty)

        await collector.flushStandardHR()
        XCTAssertEqual(store.inserted.first?.events, [
            WhoopEvent(
                ts: 1_750_000_001,
                kind: StandardHRMapping.contactEventKind,
                payload: ["contact": .string("supported_detected")]
            )
        ])
    }
}
