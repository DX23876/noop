import XCTest
@testable import StrandImport

/// Pins the WHOOP export day-keying: a cycle belongs to the WAKE day, never the onset evening.
/// Regression for the import day-shift that blanked Today for import-only users (v8.2.1).
final class WhoopDayKeyingTests: XCTestCase {

    // A real onset-to-onset cycle: fell asleep 2026-06-05 22:37 (+01:00), woke 2026-06-06 07:22.
    private let onset = Fixtures.utc(2026, 6, 5, 21, 37, 0)      // 22:37 at +01:00
    private let wake  = Fixtures.utc(2026, 6, 6, 6, 22, 0)       // 07:22 at +01:00
    private let nextOnset = Fixtures.utc(2026, 6, 6, 21, 40, 0)  // cycle end = the next evening's onset

    func testKeyedToWakeDayNotOnset() {
        XCTAssertEqual(
            WhoopDayKeying.wakeDayKey(wake: wake, end: nextOnset, start: onset, tzOffsetMin: 60),
            "2026-06-06", "the night belongs to the day you woke and read it")
        // The old onset-keyed behaviour produced the evening before — the day-shift bug.
        XCTAssertNotEqual(
            WhoopDayKeying.wakeDayKey(wake: wake, end: nextOnset, start: onset, tzOffsetMin: 60),
            "2026-06-05")
    }

    func testFallsBackToCycleEndThenStart() {
        // No wake: the cycle end (the next onset) still lands on the wake day.
        XCTAssertEqual(
            WhoopDayKeying.wakeDayKey(wake: nil, end: nextOnset, start: onset, tzOffsetMin: 60),
            "2026-06-06")
        // No wake, no end: fall back to the start (the onset evening).
        XCTAssertEqual(
            WhoopDayKeying.wakeDayKey(wake: nil, end: nil, start: onset, tzOffsetMin: 60),
            "2026-06-05")
        // Nothing usable at all → nil.
        XCTAssertNil(WhoopDayKeying.wakeDayKey(wake: nil, end: nil, start: nil, tzOffsetMin: 60))
    }
}
