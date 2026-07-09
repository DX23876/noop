import XCTest
@testable import Strand

/// `BatteryNotifier.BatteryAlertPolicy` — the pure crossing-with-hysteresis logic behind the strap
/// battery alerts (#368). Persisted `*Alerted` flags + a 25% re-arm band fire the low alert exactly
/// once per discharge cycle, so 14↔15% jitter (and a process restart) can't re-fire it. Mirrors the
/// Android `BatteryAlertPolicy` byte-for-byte. No notification/UserDefaults runtime needed here.
final class BatteryAlertPolicyTests: XCTestCase {
    private typealias Policy = BatteryNotifier.BatteryAlertPolicy

    // 1. Cross down fires once; the next reading below threshold does not re-fire.
    // NB: the threshold is `pct <= 15` (≤, not <), so the alert fires AT 15, not at 16 — 16% is
    // still above the low line. This pins that boundary so a future <-vs-≤ slip can't pass silently.
    func testCrossDownFiresOnceNoReFire() {
        // 16% is above the ≤15 line: no fire yet.
        let above = Policy.evaluate(pct: 16, charging: nil, lowAlerted: false, fullAlerted: false)
        XCTAssertFalse(above.fireLow)
        XCTAssertFalse(above.newLowAlerted)

        // First reading at/under the threshold fires once.
        let a = Policy.evaluate(pct: 15, charging: nil, lowAlerted: above.newLowAlerted, fullAlerted: above.newFullAlerted)
        XCTAssertTrue(a.fireLow)
        XCTAssertTrue(a.newLowAlerted)

        // A further drop does not re-fire.
        let b = Policy.evaluate(pct: 14, charging: nil, lowAlerted: a.newLowAlerted, fullAlerted: a.newFullAlerted)
        XCTAssertFalse(b.fireLow)
    }

    // 2. Jitter (15→14→15→14) fires the low alert only once — stays armed until pct >= 25 re-arms.
    func testJitterFiresLowOnlyOnce() {
        var low = false
        var full = false
        var fires = 0
        for pct in [15, 14, 15, 14] {
            let r = Policy.evaluate(pct: pct, charging: nil, lowAlerted: low, fullAlerted: full)
            if r.fireLow { fires += 1 }
            low = r.newLowAlerted
            full = r.newFullAlerted
        }
        XCTAssertEqual(fires, 1)
    }

    // 3. Recharge to >= 25 re-arms; a later drop to <= 15 fires the low alert again.
    func testRechargeReArmsThenFiresAgain() {
        let first = Policy.evaluate(pct: 12, charging: nil, lowAlerted: false, fullAlerted: false)
        XCTAssertTrue(first.fireLow)

        // Climb back above the re-arm band — no fire, low flag clears.
        let rearm = Policy.evaluate(pct: 30, charging: nil, lowAlerted: first.newLowAlerted, fullAlerted: first.newFullAlerted)
        XCTAssertFalse(rearm.fireLow)
        XCTAssertFalse(rearm.newLowAlerted)

        // Drop again — fires once more.
        let again = Policy.evaluate(pct: 15, charging: nil, lowAlerted: rearm.newLowAlerted, fullAlerted: rearm.newFullAlerted)
        XCTAssertTrue(again.fireLow)
    }

    // 4. charging == true suppresses the low alert even at 10%, and (#80) does NOT re-arm — an
    //    already-alerted flag stays set so the charge bit flickering to nil can't re-fire it.
    func testChargingSuppressesLowWithoutReArming() {
        // Already alerted, but now plugged in at 10% — must not fire, and the flag must STAY set.
        let r = Policy.evaluate(pct: 10, charging: true, lowAlerted: true, fullAlerted: false)
        XCTAssertFalse(r.fireLow)
        XCTAssertTrue(r.newLowAlerted)   // #80: charging must NOT re-arm

        // From a clean state, charging at 10% still suppresses.
        let clean = Policy.evaluate(pct: 10, charging: true, lowAlerted: false, fullAlerted: false)
        XCTAssertFalse(clean.fireLow)
    }

    // 4b. (#80) The strap reports its charge bit only every ~8 min, so it flickers true→nil. While low, a
    //     charging read followed by a nil read must NOT re-fire the low alert.
    func testChargeBitFlickerToNilDoesNotReFireLow() {
        var low = true   // low alert already fired (before plugging in, or on the first not-charging read)
        let charging = Policy.evaluate(pct: 12, charging: true, lowAlerted: low, fullAlerted: false)
        XCTAssertFalse(charging.fireLow); low = charging.newLowAlerted
        // Next BATTERY_LEVEL event hasn't landed yet → charge state unknown. Must stay silent.
        let gap = Policy.evaluate(pct: 12, charging: nil, lowAlerted: low, fullAlerted: false)
        XCTAssertFalse(gap.fireLow)   // was `true` before the #80 fix
    }

    // 5. Full fires once at 100%; stays quiet until pct drops below 100, then 100 again re-fires.
    func testFullFiresOnceThenReArmsBelow100() {
        let hit = Policy.evaluate(pct: 100, charging: nil, lowAlerted: false, fullAlerted: false)
        XCTAssertTrue(hit.fireFull)
        XCTAssertTrue(hit.newFullAlerted)

        // Still 100% — no re-fire.
        let hold = Policy.evaluate(pct: 100, charging: nil, lowAlerted: hit.newLowAlerted, fullAlerted: hit.newFullAlerted)
        XCTAssertFalse(hold.fireFull)

        // Drop below 100 — re-arms the full flag, no fire.
        let drop = Policy.evaluate(pct: 96, charging: nil, lowAlerted: hold.newLowAlerted, fullAlerted: hold.newFullAlerted)
        XCTAssertFalse(drop.fireFull)
        XCTAssertFalse(drop.newFullAlerted)

        // Back to 100 — fires again.
        let again = Policy.evaluate(pct: 100, charging: nil, lowAlerted: drop.newLowAlerted, fullAlerted: drop.newFullAlerted)
        XCTAssertTrue(again.fireFull)
    }

    // 6. (#514) Dropping below 100 while the full alert is standing signals clearFull exactly once,
    //    so the notifier can pull the stale "fully charged" note. It does NOT fire/clear the low alert.
    func testDropBelowFullClearsStaleFullNote() {
        // Standing full alert (fullAlerted == true) drops to 99% — clearFull, re-arms, nothing fires.
        let drop = Policy.evaluate(pct: 99, charging: nil, lowAlerted: false, fullAlerted: true)
        XCTAssertTrue(drop.clearFull)
        XCTAssertFalse(drop.fireFull)
        XCTAssertFalse(drop.fireLow)
        XCTAssertFalse(drop.newFullAlerted)

        // The next reading below 100 with the flag already re-armed does NOT keep asking to clear.
        let next = Policy.evaluate(pct: 90, charging: nil, lowAlerted: drop.newLowAlerted, fullAlerted: drop.newFullAlerted)
        XCTAssertFalse(next.clearFull)
    }

    // 7. (#514) Holding at 100 (full still standing) must NOT clear the note, and a fresh fire at
    //    100 from a clean state must NOT clear either — clearFull is the below-100 transition only.
    func testHoldingAtFullDoesNotClear() {
        let hold = Policy.evaluate(pct: 100, charging: nil, lowAlerted: false, fullAlerted: true)
        XCTAssertFalse(hold.clearFull)

        let fresh = Policy.evaluate(pct: 100, charging: nil, lowAlerted: false, fullAlerted: false)
        XCTAssertTrue(fresh.fireFull)
        XCTAssertFalse(fresh.clearFull)
    }
}
