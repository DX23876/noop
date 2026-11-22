import XCTest
@testable import NOOP

/// Pins the wait that decides when a post-offload scoring pass may start, against the owner's iPhone log
/// of 2026-11-22 — the chain that published a night of 123 minutes while 81 886 rows were still arriving.
///
/// The Kotlin twin (`android/.../ble/PostBackfillPacingTest.kt`) pins the same function on its own
/// numbers; the quiet window is shared, the cap is not, and `PostBackfillPacing` says why.
final class PostBackfillPacingTests: XCTestCase {

    func testTheQuietWindowIsTenSecondsAndTheCapIsHalfAnHour() {
        XCTAssertEqual(PostBackfillPacing.quietSeconds, 10)
        XCTAssertEqual(PostBackfillPacing.maxWaitSeconds, 1_800)
    }

    func testItKeepsWaitingWhileChunksAreStillArriving() {
        // Four seconds since the last chunk: the chain is mid-flight. This is the exact instant the old
        // two-second debounce fired on 2026-11-22 (session ended 07:53:45, next chunk 07:53:49).
        XCTAssertTrue(PostBackfillPacing.keepWaiting(now: 104, waitStartedAt: 100, lastChunkAt: 100))
    }

    func testItStopsWaitingOnceTheChunksGoQuiet() {
        XCTAssertFalse(PostBackfillPacing.keepWaiting(now: 110, waitStartedAt: 100, lastChunkAt: 100))
        XCTAssertFalse(PostBackfillPacing.keepWaiting(now: 111, waitStartedAt: 100, lastChunkAt: 100))
    }

    func testTheGapBetweenTwoSessionsOfOneChainDoesNotCountAsQuiet() {
        // The owner's chain: session one ended at 07:53:45 and session two's first chunk landed at
        // 07:53:49 — a four-second gap, inside the quiet window, so the wait rides through it. This is
        // the whole point of waiting on chunks rather than on `lastSyncedAt`.
        let sessionEnd: TimeInterval = 100
        for gap in stride(from: 0.0, through: 9.5, by: 0.5) {
            XCTAssertTrue(
                PostBackfillPacing.keepWaiting(now: sessionEnd + gap,
                                               waitStartedAt: sessionEnd,
                                               lastChunkAt: sessionEnd),
                "a \(gap)s gap between sessions must not read as quiet")
        }
    }

    func testTheOwnersTenMinuteChainIsNotCutShortByTheCap() {
        // Chunks arriving continuously for ten minutes. Android's five-minute cap would have released
        // the pass at 07:57 with the night still half offloaded; half an hour does not.
        let start: TimeInterval = 0
        var now: TimeInterval = 0
        while now < 600 {
            XCTAssertTrue(PostBackfillPacing.keepWaiting(now: now, waitStartedAt: start, lastChunkAt: now - 1),
                          "the wait must still hold at \(now)s into a live chain")
            now += 30
        }
    }

    func testTheCapIsStillASafetyValve() {
        // A chain that never goes quiet does eventually get a pass, so scoring cannot be suppressed
        // forever by a strap that keeps handing over data.
        XCTAssertFalse(PostBackfillPacing.keepWaiting(now: 1_801, waitStartedAt: 0, lastChunkAt: 1_800))
    }

    func testNoChunkAtAllMeansNothingToWaitFor() {
        // An offload that handed over nothing (a flapping link, an empty 5/MG session) must not park the
        // pass for the whole cap: there is no chain to wait out.
        XCTAssertFalse(PostBackfillPacing.keepWaiting(now: 5, waitStartedAt: 0, lastChunkAt: nil))
    }
}
