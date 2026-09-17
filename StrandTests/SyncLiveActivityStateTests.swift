import XCTest
@testable import Strand

/// The strap-sync Live Activity's words and phase (`SyncActivityCopy`). `exitBackfilling` raises
/// `lastSyncError` only when the idle watchdog ended the offload, so its presence is the one honest
/// "interrupted" signal; anything else completed. A zero backlog is dropped, as `SyncChipState` drops it.
final class SyncLiveActivityStateTests: XCTestCase {

    func testCompletedWithChunksReadsSyncedWithCount() {
        let line = SyncActivityCopy.final(lastSyncError: nil, chunks: 12)
        XCTAssertEqual(line.phase, .done)
        XCTAssertEqual(line.chunks, 12)
        XCTAssertTrue(line.status.contains("12"))
        XCTAssertNil(line.detail)
    }

    func testCompletedWithNothingPulledReadsSyncedAlone() {
        let line = SyncActivityCopy.final(lastSyncError: nil, chunks: 0)
        XCTAssertEqual(line.phase, .done)
        XCTAssertFalse(line.status.contains("0"))
    }

    func testWatchdogErrorReadsInterruptedAndKeepsTheCount() {
        let line = SyncActivityCopy.final(lastSyncError: "Sync interrupted", chunks: 3)
        XCTAssertEqual(line.phase, .interrupted)
        XCTAssertEqual(line.chunks, 3)
        XCTAssertNotNil(line.detail)
    }

    func testSyncingWithNoChunksYetClaimsNoCount() {
        let line = SyncActivityCopy.syncing(chunks: 0, pagesBehind: nil)
        XCTAssertEqual(line.phase, .syncing)
        XCTAssertFalse(line.status.contains("0"))
        XCTAssertNil(line.detail)
    }

    func testSyncingCarriesTheBacklogButDropsZero() {
        XCTAssertNotNil(SyncActivityCopy.syncing(chunks: 3, pagesBehind: 120).detail)
        XCTAssertNil(SyncActivityCopy.syncing(chunks: 3, pagesBehind: 0).detail)
    }
}
