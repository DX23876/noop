import XCTest
@testable import Strand

/// Pins the Liquid Today strap-battery ring's truth table (A3/B2,
/// docs/bugs/2026-07-15-strap-battery-backfill-observability.md).
///
/// The three inputs are independent live signals with independent sources, so the interesting cases are
/// the MIXED ones — charge % without a charging bit, a charging bit without a charge %, and a % that
/// outlived its link. Each of the three regressions below shipped, and each was visible on a wearer's
/// phone during a real strap incident. `resolve` is pure, so all of it pins with no strap and no BLE.
final class LiquidBatteryDisplayTests: XCTestCase {

    private typealias Display = LiquidTodayView.StrapBatteryDisplay

    // MARK: - A3: "charging" must not be hostage to "charge %"

    /// THE regression. `charging` rides the strap's BATTERY_LEVEL event (~every 8 min); the % rides a
    /// different characteristic entirely. So the strap can tell us it is charging long before (or without
    /// ever) telling us a number. The old view nested the bolt inside `if let pct`, making this state
    /// unrenderable — it drew `bolt.slash` at a wearer who was sitting on the charger.
    func testChargingIsReportedEvenWithNoChargeReadingYet() {
        let d = Display.resolve(connected: true, batteryPct: nil, charging: true)
        XCTAssertEqual(d, .pending(charging: true),
                       "a known charging state must survive a missing % — it is the wearer's live question")
    }

    /// The same state without the charging bit is "no reading yet", NOT "not charging" and NOT "dead".
    /// `.pending(charging: false)` and `.offline` must stay distinguishable so the view can render one as
    /// a pending ellipsis and the other as a crossed-out bolt.
    func testConnectedWithNoReadingIsPendingNotOffline() {
        let d = Display.resolve(connected: true, batteryPct: nil, charging: nil)
        XCTAssertEqual(d, .pending(charging: false))
        XCTAssertNotEqual(d, .offline, "connected-but-silent is not the same claim as no link")
    }

    // MARK: - B2: a reading must not outlive its link

    /// `LiveState.batteryPct` is never cleared — `clearBiometrics()` deliberately leaves it set (that is
    /// what makes a nil % proof the 0x2A19 read never landed). So the LAST reading survives disconnect
    /// forever, and a view keying off `batteryPct` alone shows a dead strap's stale charge as if live.
    /// During the incident that rendered a 21 h old 11% identically to a fresh one.
    func testStaleChargeIsNotShownOnceTheLinkIsGone() {
        let d = Display.resolve(connected: false, batteryPct: 11, charging: false)
        XCTAssertEqual(d, .offline, "a % with no link behind it must not render as a live reading")
    }

    /// Disconnect must also drop a charging bit — nothing about the old link is still true.
    func testStaleChargingFlagIsNotShownOnceTheLinkIsGone() {
        XCTAssertEqual(Display.resolve(connected: false, batteryPct: nil, charging: true), .offline)
    }

    // MARK: - The normal path still reads normally

    func testConnectedReadingCarriesPctAndChargingThrough() {
        XCTAssertEqual(Display.resolve(connected: true, batteryPct: 87.4, charging: true),
                       .charge(pct: 87.4, charging: true))
        XCTAssertEqual(Display.resolve(connected: true, batteryPct: 87.4, charging: false),
                       .charge(pct: 87.4, charging: false))
    }

    /// `charging` is `Bool?` — nil means "the strap hasn't said" (no BATTERY_LEVEL event this session),
    /// which must read as not-charging, never as charging. Same `== true` posture as the rest of the app.
    func testUnknownChargingReadsAsNotCharging() {
        XCTAssertEqual(Display.resolve(connected: true, batteryPct: 50, charging: nil),
                       .charge(pct: 50, charging: false))
    }
}
