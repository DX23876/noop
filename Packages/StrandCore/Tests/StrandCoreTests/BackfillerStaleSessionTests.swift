import XCTest
import StrandCore
import WhoopProtocol
import WhoopStore

/// An END whose session ended while its writes were suspended must not ack, write the cursor, or count its rows
/// into the next session: an ack frees strap flash, and on a new link it would reach the strap out of sequence.
/// The idle timeout is not such a boundary. A restore that replaced the store under the process holds every ack.
@MainActor
final class BackfillerStaleSessionTests: XCTestCase {
    @MainActor private final class CursorStore: BackfillStoreWriting {
        var cursors: [Int] = []

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        #if canImport(Compression)
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        #endif
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

    /// A record that needs archiving, so the END suspends in the archive sink where the test holds it.
    private func rejectedRecord() -> [UInt8] {
        var frame = frameFromPayload([1, 2, 3], type: 47, seq: 25)
        frame[frame.count - 1] ^= 0xff
        return frame
    }

    private struct Rig {
        let store: CursorStore
        let gate: ArchiveGate
        let backfiller: Backfiller
        let acked: () -> [UInt32]
        let lines: () -> [String]
    }

    private func rig() -> Rig {
        let store = CursorStore()
        let gate = ArchiveGate()
        var acked: [UInt32] = []
        var lines: [String] = []
        let backfiller = Backfiller(store: store, deviceId: "test",
                                    ackTrim: { trim, _ in acked.append(trim) },
                                    log: { lines.append($0) },
                                    rejectedSink: { _, _, _ in await gate.wait() })
        return Rig(store: store, gate: gate, backfiller: backfiller, acked: { acked }, lines: { lines })
    }

    /// Starts an END that suspends in the archive, runs `boundary` while it waits, then lets the archive succeed.
    private func endAcross(_ r: Rig, boundary: () -> Void) async {
        r.backfiller.begin(family: .whoop4)
        await r.backfiller.ingest(rejectedRecord())
        let pending = Task { await r.backfiller.ingest(historyEnd(trim: 42)) }
        await fulfillment(of: [r.gate.entered], timeout: 2)
        boundary()
        r.gate.finish(true)
        await pending.value
    }

    func testAnEndWhoseLinkEndedDuringItsWritesIsNotAcked() async {
        let r = rig()
        await endAcross(r) { r.backfiller.linkEnded() }
        XCTAssertTrue(r.acked().isEmpty, r.lines().joined(separator: "\n"))
        XCTAssertTrue(r.store.cursors.isEmpty, "the cursor must not advance for a chunk the strap keeps")
        XCTAssertEqual(r.lines().filter { $0.contains("offload session ended while chunk trim=42") }.count, 1)
    }

    func testAnEndWhoseSessionWasReplacedByTheNextOneIsNotAcked() async {
        let r = rig()
        await endAcross(r) { r.backfiller.begin(family: .whoop4) }
        XCTAssertTrue(r.acked().isEmpty)
        XCTAssertTrue(r.store.cursors.isEmpty)
    }

    /// An END still writing when the idle watchdog fires is on the same link with no session after it: its ack is
    /// honest, and holding it would re-send the chunk into the same slow write every session.
    func testTheIdleTimeoutDoesNotStrandAnEndStillWriting() async {
        let r = rig()
        await endAcross(r) { r.backfiller.timeoutFired() }
        XCTAssertEqual(r.acked(), [42])
        XCTAssertEqual(r.store.cursors, [42])
    }

    func testAnEndOnTheSameSessionStillAcks() async {
        let r = rig()
        await endAcross(r) {}
        XCTAssertEqual(r.acked(), [42])
        XCTAssertEqual(r.store.cursors, [42])
        XCTAssertTrue(r.lines().filter { $0.contains("offload session ended") }.isEmpty)
    }

    func testAReplacedStoreHoldsEveryAck() async {
        let store = CursorStore()
        var acked: [UInt32] = []
        var lines: [String] = []
        let backfiller = Backfiller(store: store, deviceId: "test",
                                    ackTrim: { trim, _ in acked.append(trim) },
                                    log: { lines.append($0) })
        backfiller.storeReplaced = { true }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(historyEnd(trim: 42))
        await backfiller.ingest(historyEnd(trim: 43))
        XCTAssertTrue(acked.isEmpty)
        XCTAssertTrue(store.cursors.isEmpty)
        XCTAssertEqual(lines.filter { $0.contains("replaced by a restore") }.count, 1, "said once per session")
    }
}
