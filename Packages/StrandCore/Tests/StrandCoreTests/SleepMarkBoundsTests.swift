import XCTest
@testable import StrandCore

/// The wearer's taps as the bounds of a detected night: only inside it, only inward, never below an hour.
final class SleepMarkBoundsTests: XCTestCase {
    private let h = 3_600

    func testABedtimeTapLaterThanTheDetectedStartMovesTheStart() {
        // Detected from 2 am (awake in bed) to 11 am; "going to sleep" tapped at 4 am.
        let b = SleepMarkBounds.bounds(start: 2 * h, end: 11 * h, bedtimes: [4 * h], wakes: [])
        XCTAssertEqual(b?.start, 4 * h)
        XCTAssertEqual(b?.end, 11 * h)
    }

    func testAWakeTapBeforeTheDetectedEndMovesTheEnd() {
        let b = SleepMarkBounds.bounds(start: 0, end: 9 * h, bedtimes: [], wakes: [7 * h])
        XCTAssertEqual(b?.start, 0)
        XCTAssertEqual(b?.end, 7 * h)
    }

    func testTapsOutsideTheNightOrOnTheWrongHalfChangeNothing() {
        XCTAssertNil(SleepMarkBounds.bounds(start: 0, end: 8 * h, bedtimes: [-h], wakes: [9 * h]), "outside")
        XCTAssertNil(SleepMarkBounds.bounds(start: 0, end: 8 * h, bedtimes: [6 * h], wakes: [h]),
                     "a bedtime late in the night or a wake early in it is no bound for this night")
    }

    func testANightIsNeverCutBelowAnHour() {
        XCTAssertNil(SleepMarkBounds.bounds(start: 0, end: 2 * h, bedtimes: [h - 60], wakes: [h + 60]))
    }

    func testSeveralTapsTakeTheLatestBedtimeAndTheEarliestWake() {
        let b = SleepMarkBounds.bounds(start: 0, end: 10 * h, bedtimes: [h, 2 * h], wakes: [8 * h, 9 * h])
        XCTAssertEqual(b?.start, 2 * h)
        XCTAssertEqual(b?.end, 8 * h)
    }
}
