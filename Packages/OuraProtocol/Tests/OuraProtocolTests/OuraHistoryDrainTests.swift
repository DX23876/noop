import XCTest
@testable import OuraProtocol

/// Pins the Oura history drain + resume-cursor decisions (#91 / #291) that used to live untested inside
/// OuraLiveSource and silently regressed in a BLE refactor. Pure decisions — no ring, no BLE.
final class OuraHistoryDrainTests: XCTestCase {

    // MARK: drain continuation

    func testDrainCompletesWhenBytesLeftZero() {
        var d = OuraHistoryDrain()
        // moreData == false is the healthy end, regardless of the counters.
        XCTAssertFalse(d.onSummary(bytesLeft: 0, moreData: false, elapsedSeconds: 0))
    }

    func testDrainContinuesWhileBytesLeftShrinks() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 400_873, moreData: true, elapsedSeconds: 1))
        XCTAssertTrue(d.onSummary(bytesLeft: 200_000, moreData: true, elapsedSeconds: 2))
        XCTAssertTrue(d.onSummary(bytesLeft: 1, moreData: true, elapsedSeconds: 3))
    }

    func testStallGuardStopsAfterMaxFlatSummaries() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1)) // sets the floor
        // Same bytes_left repeated — no progress. Stops on the maxStallSummaries-th flat read.
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 2))  // stall 1
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 3))  // stall 2
        XCTAssertFalse(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 4)) // stall 3 -> stop
    }

    func testStallCounterResetsOnFreshProgress() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1))
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 2)) // stall 1
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 3))  // progress -> reset
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 4))  // stall 1 again
        XCTAssertTrue(d.onSummary(bytesLeft: 900, moreData: true, elapsedSeconds: 5))  // stall 2 (not stopped)
    }

    func testDeadlineGuardStopsPastMaxDrainSeconds() {
        var d = OuraHistoryDrain()
        XCTAssertTrue(d.onSummary(bytesLeft: 500, moreData: true, elapsedSeconds: 299))
        XCTAssertFalse(d.onSummary(bytesLeft: 400, moreData: true,
                                   elapsedSeconds: OuraHistoryDrain.maxDrainSeconds + 0.1))
    }

    // MARK: stored ring-time → cursor

    func testNoteStoredRingTimeTracksMaxAndIgnoresCorrupt() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(100, resumeCursorAtFetchStart: 0)
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 0)
        d.noteStoredRingTime(50, resumeCursorAtFetchStart: 0) // older, doesn't lower the max
        XCTAssertEqual(d.maxStoredRingTime, 3_453_828)
        d.noteStoredRingTime(OuraHistoryDrain.maxPlausibleResumeTicks + 1, resumeCursorAtFetchStart: 0)
        XCTAssertEqual(d.maxStoredRingTime, 3_453_828, "over-ceiling ring-time must be ignored")
        XCTAssertFalse(d.sawPreResumeData)
    }

    func testPreResumeDataFlagsReboot() {
        var d = OuraHistoryDrain()
        // We sought from cursor 1000; a real sample at 500 is OLDER than the seek → ring reset / seek ignored.
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)
        XCTAssertTrue(d.sawPreResumeData)
    }

    func testFullPullSeekNeverFlagsReboot() {
        var d = OuraHistoryDrain()
        // A full pull seeks from 0 (no floor); early samples must NOT be treated as pre-resume.
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 0)
        XCTAssertFalse(d.sawPreResumeData)
    }

    // MARK: cursor commit

    func testResumeCursorAdvancesWhenForwardAndResolves() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 3_453_828)
    }

    func testResumeCursorUnchangedWhenNotResolving() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: false), 1000)
    }

    func testResumeCursorUnchangedWhenNotForward() {
        var d = OuraHistoryDrain()
        // Newest stored sample EQUALS the cursor (no new data past it) — not forward, and not a reboot
        // (a sample strictly BELOW the seek would flag `sawPreResumeData`, tested separately).
        d.noteStoredRingTime(1000, resumeCursorAtFetchStart: 1000)
        XCTAssertFalse(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 1000)
    }

    func testRebootResetsCursorToFullPull() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000) // forward...
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)       // ...but also a pre-resume sample
        XCTAssertTrue(d.sawPreResumeData)
        XCTAssertEqual(d.resumeCursorAtDrainEnd(currentCursor: 1000, resolvesUnderAnchor: true), 0,
                       "a reboot forces 0 (full pull) even if a forward sample also arrived")
    }

    // MARK: loaded-cursor sanitize + reset

    func testSanitizeLoadedCursor() {
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(3_453_828), 3_453_828)
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(0), 0)
        XCTAssertEqual(OuraHistoryDrain.sanitizeLoadedCursor(OuraHistoryDrain.maxPlausibleResumeTicks + 1), 0,
                       "a persisted cursor above the ceiling is pre-fix garbage → full pull")
    }

    func testResetClearsState() {
        var d = OuraHistoryDrain()
        d.noteStoredRingTime(3_453_828, resumeCursorAtFetchStart: 1000)
        d.noteStoredRingTime(500, resumeCursorAtFetchStart: 1000)
        _ = d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1)
        d.reset()
        XCTAssertEqual(d.maxStoredRingTime, 0)
        XCTAssertFalse(d.sawPreResumeData)
        // Stall floor reset: a fresh flat sequence starts counting from scratch.
        XCTAssertTrue(d.onSummary(bytesLeft: 1000, moreData: true, elapsedSeconds: 1))
    }
}
