import XCTest
@testable import Strand

/// The offload drain stays single-flight across a reconnect: when an ingest suspends (a chunk's END awaiting its
/// store write) and the link drops, the next link's drain waits for it, and the old drain stops at its resume
/// instead of carrying on with the new link's frames. While that old ingest runs, its ack is judged stale.
/// Adapted from ayiskakov/noop (W06-008, W06-125).
@MainActor
final class BackfillDrainLinkTests: XCTestCase {
    /// Holds the ingest of one chosen frame until the test lets it go.
    @MainActor private final class IngestGate {
        let entered = XCTestExpectation(description: "the held ingest has started")
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testTheNextLinksFramesWaitForTheSuspendedIngestAndItsAckIsStale() async {
        let gate = IngestGate()
        var ingested: [UInt8] = []
        var staleDuringHeldIngest: Bool?
        var lines: [String] = []
        var drain: BackfillDrain!
        drain = BackfillDrain(batchSize: 12, ingest: { frame in
            if frame == [0xA2] {
                await gate.wait()
                staleDuringHeldIngest = drain.ingestOutlivedItsLink
            }
            ingested.append(frame[0])
        }, afterIngest: { true }, log: { lines.append($0) })

        // Link A: the END frame suspends in its ingest, with one more A frame queued behind it.
        drain.route([0xA1])
        drain.route([0xA2])
        drain.route([0xA3])
        await fulfillment(of: [gate.entered], timeout: 2)
        // The link drops and the next one starts its offload while A's END is still writing.
        drain.linkEnded()
        drain.route([0xB1])
        drain.route([0xB2])
        await Task.yield()
        XCTAssertEqual(ingested, [0xA1], "link B's frames must not be ingested beside A's suspended END")

        gate.release()
        await drain.settle()
        XCTAssertEqual(staleDuringHeldIngest, true, "the END that began on A asks for an ack on B")
        XCTAssertEqual(ingested, [0xA1, 0xA2, 0xB1, 0xB2], "A's queued frame is dropped with its link")
        XCTAssertFalse(drain.ingestOutlivedItsLink)
        XCTAssertEqual(lines.filter { $0.contains("waits for the previous link's drain") }.count, 1)
        XCTAssertEqual(lines.filter { $0.contains("link ended during an ingest") }.count, 1)
    }

    func testAnIngestOnTheCurrentLinkIsNotStale() async {
        var stale: [Bool] = []
        var drain: BackfillDrain!
        drain = BackfillDrain(batchSize: 12, ingest: { _ in stale.append(drain.ingestOutlivedItsLink) },
                              afterIngest: { true })
        drain.route([1])
        drain.route([2])
        await drain.settle()
        XCTAssertEqual(stale, [false, false])
    }

    func testAnEndedSessionDropsWhatIsQueued() async {
        var ingested: [UInt8] = []
        let drain = BackfillDrain(batchSize: 12, ingest: { ingested.append($0[0]) }, afterIngest: { false })
        drain.route([1])
        drain.route([2])
        await drain.settle()
        XCTAssertEqual(ingested, [1])
    }
}
