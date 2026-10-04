import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

@MainActor
final class BackfillerRejectedArchiveOrderingTests: XCTestCase {
    @MainActor private final class CursorStore: BackfillStoreWriting {
        var cursors: [Int] = []

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws { cursors.append(value) }
        func cursor(_ name: String) async throws -> Int? { cursors.last }
    }

    @MainActor private final class ArchiveGate {
        let entered = XCTestExpectation(description: "archive has started")
        var continuation: CheckedContinuation<Bool, Never>?

        func wait() async -> Bool {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }
        func finish(_ success: Bool) { continuation?.resume(returning: success); continuation = nil }
    }

    private func historyEnd(trim: UInt32) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
             UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
        }
        return frameFromPayload(le32(1_700_000_000) + [0, 0] + le32(0) + le32(trim),
                                type: 49, seq: 0, cmd: 2)
    }

    private func rejectedRecord() -> [UInt8] {
        var frame = frameFromPayload([1, 2, 3], type: 47, seq: 25)
        frame[frame.count - 1] ^= 0xff // Keep the type; damage the CRC so this record needs archiving.
        return frame
    }

    func testArchiveSuspensionHoldsCursorAndAckUntilBytesAreDurable() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-archive-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir)
        let store = CursorStore()
        let gate = ArchiveGate()
        var acked: [UInt32] = []
        let backfiller = Backfiller(store: store, deviceId: "test",
            ackTrim: { trim, _ in
                XCTAssertEqual(archive.readAll().count, 1, "the only surviving copy must exist before ack")
                acked.append(trim)
            }, rejectedSink: { frames, trim, family in
                guard await gate.wait() else { return false }
                let result = await Task.detached(priority: .utility) {
                    archive.archive(frames, trim: trim, family: family)
                }.value
                guard case .written(count: 1) = result else { return false }
                return true
            })
        backfiller.begin(family: .whoop4)
        let record = rejectedRecord()
        XCTAssertEqual(rejectedHistoricalRecords([record], family: .whoop4).count, 1)
        await backfiller.ingest(record)
        let pending = Task { await backfiller.ingest(historyEnd(trim: 42)) }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertTrue(store.cursors.isEmpty, "cursor must not advance while archive is pending")
        XCTAssertTrue(acked.isEmpty, "strap must retain the frame until archive is durable")
        gate.finish(true)
        await pending.value
        XCTAssertEqual(store.cursors, [42])
        XCTAssertEqual(acked, [42])
    }

    func testArchiveFailureHoldsThisAndLaterChunkAcks() async {
        let store = CursorStore()
        var acked: [UInt32] = []
        let backfiller = Backfiller(store: store, deviceId: "test",
            ackTrim: { trim, _ in acked.append(trim) },
            rejectedSink: { _, _, _ in false })
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(rejectedRecord())
        await backfiller.ingest(historyEnd(trim: 42))
        // The empty next chunk cannot silently trim past the one whose archive failed.
        await backfiller.ingest(historyEnd(trim: 43))
        XCTAssertTrue(store.cursors.isEmpty)
        XCTAssertTrue(acked.isEmpty)
    }
}
