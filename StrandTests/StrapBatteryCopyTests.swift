import XCTest
import SwiftUI
import StrandDesign
@testable import Strand

/// Pins the strap-battery read-outs that every compact surface now shares.
///
/// The runtime badge lived twice, character for character (`TodayView` and the Liquid row, whose comment
/// admitted it was "Reproduced verbatim"), and the level tint lived twice with DIFFERENT thresholds — so
/// one strap at 32 % read amber on Today and green on a dashboard. Both are one function now; these tests
/// are what stop a third copy re-appearing with its own boundaries.
final class StrapBatteryCopyTests: XCTestCase {

    // MARK: - Runtime badge

    func testUnderTwoDaysReadsInHours() {
        XCTAssertEqual(StrapBatteryCopy.runtimeBadge(hoursRemaining: 6, charging: false), "~6h left")
        // 47.9 h is still hours; the boundary is the interesting part, not the middle of a range.
        XCTAssertEqual(StrapBatteryCopy.runtimeBadge(hoursRemaining: 47.9, charging: false), "~48h left")
    }

    func testTwoDaysAndOverRoundsToDays() {
        XCTAssertEqual(StrapBatteryCopy.runtimeBadge(hoursRemaining: 48, charging: false), "~2 days left")
        XCTAssertEqual(StrapBatteryCopy.runtimeBadge(hoursRemaining: 216, charging: false), "~9 days left")
    }

    /// Both originals carried a singular "~1 day left" arm that could never run: the day arm starts at
    /// 48 h and 48 / 24 rounds to 2. A day's worth of runtime is inside the HOURS arm, and reads as such.
    func testADaysWorthOfRuntimeStillReadsInHours() {
        XCTAssertEqual(StrapBatteryCopy.runtimeBadge(hoursRemaining: 26, charging: false), "~26h left")
    }

    /// #713's honesty rule: no estimate is shown unless it is one we can stand behind. Charging invalidates
    /// a discharge-derived runtime, and a missing/degenerate estimate must not render as "~0h left".
    func testNoBadgeWithoutATrustedEstimate() {
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: 6, charging: true))
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: nil, charging: false))
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: 0, charging: false))
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: -3, charging: false))
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: .infinity, charging: false))
        XCTAssertNil(StrapBatteryCopy.runtimeBadge(hoursRemaining: .nan, charging: false))
    }

    // MARK: - Level tint

    /// The canonical thresholds are the menu-bar stat's (`MenuBarContent.batteryTone`), which Today's own
    /// row already named as its source. The dashboard control's old second set (`<=15` / `<=30`) is what
    /// made 32 % disagree between two screens — 32 is the case that pins it.
    func testToneUsesTheOneCanonicalThresholdSet() {
        XCTAssertEqual(StrapBatteryDisplayState.tone(14.9), .critical)
        XCTAssertEqual(StrapBatteryDisplayState.tone(15), .warning)
        XCTAssertEqual(StrapBatteryDisplayState.tone(32), .warning)
        XCTAssertEqual(StrapBatteryDisplayState.tone(34.9), .warning)
        XCTAssertEqual(StrapBatteryDisplayState.tone(35), .positive)
        XCTAssertEqual(StrapBatteryDisplayState.tone(100), .positive)
    }

    // MARK: - Display state

    func testResolveNeverPresentsAStalePercentAsCurrent() {
        // A percentage that outlived its Bluetooth link is offline, not a reading.
        XCTAssertEqual(StrapBatteryDisplayState.resolve(connected: false, batteryPct: 88, charging: false),
                       .offline)
        XCTAssertEqual(StrapBatteryDisplayState.resolve(connected: true, batteryPct: nil, charging: true),
                       .pending(charging: true))
        XCTAssertEqual(StrapBatteryDisplayState.resolve(connected: true, batteryPct: 88, charging: false),
                       .charge(pct: 88, charging: false))
        // Out-of-range readings are clamped rather than drawn as an over-full ring.
        XCTAssertEqual(StrapBatteryDisplayState.resolve(connected: true, batteryPct: 140, charging: false),
                       .charge(pct: 100, charging: false))
        XCTAssertEqual(StrapBatteryDisplayState.resolve(connected: true, batteryPct: -5, charging: false),
                       .charge(pct: 0, charging: false))
    }

    func testPercentTextRounds() {
        XCTAssertEqual(StrapBatteryCopy.percentText(86.6), "87%")
    }
}
