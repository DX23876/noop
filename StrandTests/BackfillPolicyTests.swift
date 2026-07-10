import XCTest
@testable import Strand

/// `BackfillPolicy` rate-limiter, incl. the empty-streak backoff that stops an off-wrist / not-banking
/// strap from being re-offloaded every event floor (#77/#120/#216). Pure value logic, no CoreBluetooth seam.
final class BackfillPolicyTests: XCTestCase {
    private let fe = BackfillPolicy.eventFloorSeconds      // 90
    private let fp = BackfillPolicy.periodicFloorSeconds   // 900

    func testFirstSyncAlwaysRuns() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .periodic, now: 1000, lastBackfillAt: nil))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: nil))
    }

    func testManualAlwaysRunsRegardlessOfFloorOrStreak() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999, emptyStreak: 99))
    }

    // #364: the expedited auto-continue is deliberately un-floored like .manual — it must run even
    // immediately after the previous backfill (a 60s session just ended). Its runaway protection lives in
    // BLEManager's consecutive-cap + trim spin-detector, NOT in this policy, so the floor must NOT block it.
    func testAutoContinueAlwaysRunsRegardlessOfFloorOrStreak() {
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 999, emptyStreak: 99))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 1000))
    }

    func testBaselineFloors() {
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp + 1))
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: 10000 - fp))
    }

    func testEmptyStreakBacksOffStrap() {
        // 200s elapsed: passes at baseline (floor 90), blocked once the 4x cap applies (floor 360).
        let last = 1000.0 - 200
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 5))
    }

    func testBackoffIsGraduatedThenCapped() {
        // streak 3 → 2x floor (180s): 100s elapsed passes at baseline, blocked at 2x.
        let last = 1000.0 - 100
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 0))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last, emptyStreak: 3))
        // cap holds: a huge streak never stretches beyond 4x (floor 360); 360s elapsed still passes.
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: 1000 - fe * 4, emptyStreak: 99))
    }

    func testBackoffNeverDelaysConnectOrForeground() {
        let last = 1000 - fe   // exactly at the baseline event floor
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: last, emptyStreak: 99))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: last, emptyStreak: 99))
    }

    // MARK: - #160: future-dated clock backoff

    /// A strap whose RTC reads future-dated (#928) still banks real rows every pass, so it never trips
    /// emptyStreak — clockUntrusted must independently stretch the .strap floor to the SAME cap.
    func testClockUntrustedBacksOffStrapEvenWithNoEmptyStreak() {
        let last = 1000.0 - 200   // passes the baseline (90s) floor, blocked once the 4x cap applies (360s)
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last,
                                                emptyStreak: 0, clockUntrusted: false))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last,
                                                emptyStreak: 0, clockUntrusted: true))
    }

    func testClockUntrustedBacksOffPeriodicToo() {
        let last = 10000.0 - 1000   // passes the baseline (900s) floor, blocked once the 4x cap applies (3600s)
        XCTAssertTrue (BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: last,
                                                clockUntrusted: false))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .periodic, now: 10000, lastBackfillAt: last,
                                                clockUntrusted: true))
    }

    /// clockUntrusted maxes the backoff immediately (no streak to build), so it's already at the 4x cap
    /// a huge emptyStreak would also reach — the two signals must not stack past maxEmptyBackoff.
    func testClockUntrustedDoesNotStackBeyondCapWithEmptyStreak() {
        let last = 1000.0 - fe * 4   // exactly at the 4x-capped floor
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .strap, now: 1000, lastBackfillAt: last,
                                               emptyStreak: 99, clockUntrusted: true))
    }

    /// Same invariant as emptyStreak: clockUntrusted must never delay a user- or connection-driven sync.
    func testClockUntrustedNeverDelaysConnectForegroundManualOrAutoContinue() {
        let last = 1000 - fe
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 1000, lastBackfillAt: last, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .foreground, now: 1000, lastBackfillAt: last, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .manual, now: 1000, lastBackfillAt: 999, clockUntrusted: true))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .autoContinue, now: 1000, lastBackfillAt: 999, clockUntrusted: true))
    }
}
