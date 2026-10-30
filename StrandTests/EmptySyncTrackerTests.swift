import XCTest
@testable import Strand

/// Pins the #126 false-alarm guard on the #77/#91/#120 "your strap's clock has lost sync" banner. The
/// banner used to fire on a SINGLE completed sync that handed over only the strap's console/diagnostic
/// output — but a healthy strap can produce one such empty cycle, especially under heavy live-HR polling,
/// so it false-alarmed users (NoahMcE, #126) whose clock was banking fine. EmptySyncTracker requires
/// CONSECUTIVE empty cycles before the banner shows; any banking cycle clears the streak. Pure value type.
final class EmptySyncTrackerTests: XCTestCase {

    // A single console-only cycle must NOT warn — that's the #126 false alarm we're fixing.
    func testSingleEmptyCycleDoesNotWarn() {
        var t = EmptySyncTracker()        // default threshold 3
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 1)
    }

    // Two console-only cycles still below threshold — still silent.
    func testTwoEmptyCyclesStillSilent() {
        var t = EmptySyncTracker()
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 2)
    }

    // Three CONSECUTIVE console-only cycles = sustained emptiness ⇒ warn (a genuinely un-banking strap).
    func testThreeConsecutiveEmptyCyclesWarn() {
        var t = EmptySyncTracker()
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 3)
    }

    // A banking cycle in the middle clears the streak — this is exactly NoahMcE's case (2 empty cycles
    // sprinkled among 14 healthy ones never accumulate to a warning).
    func testBankingCycleClearsStreak() {
        var t = EmptySyncTracker()
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: true, consoleOnly: false),
                       "a cycle that banked records resets the streak")
        XCTAssertEqual(t.consecutiveEmptySyncs, 0)
        // ...and it now takes the full threshold again to warn.
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
    }

    // A caught-up sync (nothing to offload: not console-only, didn't bank) also clears the streak — it's
    // not evidence the strap stopped banking.
    func testCaughtUpCycleClearsStreak() {
        var t = EmptySyncTracker()
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: false),
                       "caught-up (no console flood, nothing banked) is not an empty-banking failure")
        XCTAssertEqual(t.consecutiveEmptySyncs, 0)
    }

    // A genuinely un-banking strap (console-only EVERY cycle) keeps warning once tripped.
    func testSustainedEmptinessKeepsWarning() {
        var t = EmptySyncTracker()
        _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true)
        _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true)
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true),
                      "still un-banking — keep warning")
    }

    // A custom lower threshold trips sooner.
    func testCustomThreshold() {
        var t = EmptySyncTracker(threshold: 2)
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true))
    }

    // An off-wrist strap handing over nothing says nothing about its clock: the cycle neither counts nor clears.
    func testAnOffWristEmptyCycleNeitherCountsNorClears() {
        var t = EmptySyncTracker()
        _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true)
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        XCTAssertFalse(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 1)
    }

    // ...but a banner on-wrist cycles already raised stays up while the strap sits on a charger.
    func testAnOffWristCycleKeepsABannerAlreadyRaised() {
        var t = EmptySyncTracker()
        for _ in 0..<3 { _ = t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true) }
        XCTAssertTrue(t.recordCompletedSync(bankedSensorRecords: false, consoleOnly: true, strapOffWrist: true))
        XCTAssertEqual(t.consecutiveEmptySyncs, 3)
    }
}
