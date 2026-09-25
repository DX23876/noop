import XCTest
@testable import Strand

/// Regression for the 2026-07-17 capture: an overnight hypnogram burst and a ~3PM nap burst finalized in
/// the SAME history drain. The old single-slot `lastSleepWindow049` let the nap's 0x49 window overwrite
/// the overnight's before the overnight burst persisted, so the overnight fell back to its SleepNet WRITE
/// time (10:58, ~4 h after the true 07:00 sleep end) instead of the 0x49-refined end. The fix keeps a
/// COLLECTION and pairs each burst with the CLOSEST window by ring-time — these tests pin that picker.
final class OuraSleepWindowPairingTests: XCTestCase {

    // Ring-time is deciseconds; 6000 ticks = 10 min is the pairing tolerance. Two windows a night apart.
    private let overnight: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (8_400_000, 778, 238)
    private let nap: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (8_512_000, 44, 34)

    // THE bug: with both windows stashed (nap appended LAST), the overnight burst must still pick the
    // overnight window, not the most-recent (nap) one.
    func testOvernightBurstPicksOvernightWindowDespiteLaterNap() {
        let windows = [overnight, nap]
        let overnightBurstRt: UInt32 = overnight.ringTimestamp + 50   // 5 s after the 0x49 event
        let picked = OuraLiveSource.closestSleepWindow049(in: windows, toRingTimestamp: overnightBurstRt, within: 6_000)
        XCTAssertEqual(picked?.ringTimestamp, overnight.ringTimestamp)
        XCTAssertEqual(picked?.endOffMin, 238)
    }

    // The nap burst still pairs with the nap window.
    func testNapBurstPicksNapWindow() {
        let windows = [overnight, nap]
        let napBurstRt: UInt32 = nap.ringTimestamp + 30
        let picked = OuraLiveSource.closestSleepWindow049(in: windows, toRingTimestamp: napBurstRt, within: 6_000)
        XCTAssertEqual(picked?.ringTimestamp, nap.ringTimestamp)
        XCTAssertEqual(picked?.endOffMin, 34)
    }

    // A burst with no window within tolerance gets nil (caller keeps the write-time fallback) — never a
    // far-off mis-pair. This is the honest degradation the old code lost when it grabbed the last slot.
    func testNoWindowInRangeReturnsNil() {
        let windows = [nap]   // only the nap stashed; an overnight burst is ~3 h away
        let overnightBurstRt: UInt32 = overnight.ringTimestamp + 50
        XCTAssertNil(OuraLiveSource.closestSleepWindow049(in: windows, toRingTimestamp: overnightBurstRt, within: 6_000))
    }

    // Closest wins when two windows both sit within tolerance.
    func testClosestOfTwoInRangeWins() {
        let near: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (10_000, 600, 10)
        let far: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (13_000, 600, 20)
        let picked = OuraLiveSource.closestSleepWindow049(in: [far, near], toRingTimestamp: 10_500, within: 6_000)
        XCTAssertEqual(picked?.endOffMin, 10)   // near (gap 500) beats far (gap 2500)
    }

    // Exact tolerance boundary is inclusive; one past it is excluded.
    func testToleranceBoundaryInclusive() {
        let w: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (100_000, 600, 10)
        XCTAssertNotNil(OuraLiveSource.closestSleepWindow049(in: [w], toRingTimestamp: 100_000 - 6_000, within: 6_000))
        XCTAssertNil(OuraLiveSource.closestSleepWindow049(in: [w], toRingTimestamp: 100_000 - 6_001, within: 6_000))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(OuraLiveSource.closestSleepWindow049(in: [], toRingTimestamp: 8_400_000, within: 6_000))
    }

    // MARK: - The stash survives a reconnect (2026-09-24 capture)

    // Ring times from the 09-24 capture, derived from that morning's SyncTime anchor (rt 53_289_426 at
    // 07:30:37): the 0x49 event at 07:16:23, the fetch that delivered it caught up at 07:16:31, and the
    // SleepNet phase records were written at 07:16:35 — AFTER that fetch, so they came on the next one.
    private let window0924: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int) = (53_280_886, 503, 0)
    private let cursorAfter0x49Fetch: UInt32 = 53_280_976
    private let burst0924: UInt32 = 53_281_006

    /// The shape of the defect: the fetch caught up BETWEEN the ring's 0x49 and its burst, so the two can
    /// only meet if the stash outlives the fetch — and, when the link drops in between, the connection.
    func testThe0924BurstLandedAfterTheFetchThatCarriedIts0x49() {
        XCTAssertLessThan(window0924.ringTimestamp, cursorAfter0x49Fetch)
        XCTAssertGreaterThan(burst0924, cursorAfter0x49Fetch)
    }

    /// With the window still stashed on the next connection, the burst pairs with it (12 s apart), so the
    /// night is anchored at the ring's own 22:53 onset instead of persisting `[no-0x49-onset]` at 22:36.
    func testAKeptWindowPairsWithTheBurstOnTheNextConnection() {
        let w = OuraLiveSource.closestSleepWindow049(in: [window0924], toRingTimestamp: burst0924, within: 6_000)
        XCTAssertEqual(w?.ringTimestamp, window0924.ringTimestamp)
        XCTAssertEqual(w?.startOffMin, 503)
    }

    /// THE REGRESSION TEST. A link boundary keeps the stash; only a deliberate teardown clears it.
    func testTheStashIsKeptAcrossALinkBoundaryAndClearedOnTeardown() {
        XCTAssertFalse(OuraLiveSource.clearsSleepWindowStash(at: .linkBoundary))
        XCTAssertTrue(OuraLiveSource.clearsSleepWindowStash(at: .teardown))
    }
}
