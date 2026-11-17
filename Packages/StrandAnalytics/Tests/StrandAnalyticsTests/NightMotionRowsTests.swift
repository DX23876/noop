import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The gate that decides whether a day's night can be staged from motion at all (#2890, reported
/// 2026-11-17).
///
/// The day's read window is 54 hours wide (`dayStart − 30 h` through the night, `StreamReadCap`), and the
/// gate used to count gravity across ALL of it. A strap that streamed motion the day before yesterday and
/// nothing since therefore kept the heart-rate-only fallback shut on every following night: the window
/// had rows, the night had none, and the night scored as nothing at all. Gravity reaches the store only
/// through the history offload, so any strap whose offload stalls — not only the firmware that stopped
/// serving history — ends up exactly there.
///
/// `nightMotionRows` asks the question the gate actually means: how much motion lies in the hours THIS
/// day's night can occupy.
final class NightMotionRowsTests: XCTestCase {

    /// Local midnight of an arbitrary day; every timestamp below is relative to it, so the test reads as
    /// "so many hours before/after midnight" rather than as epochs.
    private let dayStart = 1_763_337_600

    private func grav(_ offsets: [Int]) -> [GravitySample] {
        offsets.map { GravitySample(ts: dayStart + $0, x: 0, y: 0, z: 1) }
    }

    /// The reported case: motion stopped a day and a half before this night, inside the lookback the
    /// window reads but outside the night it describes.
    func testMotionFromBeforeTheNightDoesNotCount() {
        let staleLookback = grav([-30 * 3_600, -26 * 3_600, -20 * 3_600, -13 * 3_600])
        XCTAssertEqual(SleepStager.nightMotionRows(staleLookback, dayStart: dayStart), 0)
    }

    /// A night with motion is untouched: an ordinary strap streams gravity through the small hours.
    func testMotionInTheNightCounts() {
        let night = grav([-2 * 3_600, -3_600, 0, 3_600, 3 * 3_600, 6 * 3_600])
        XCTAssertEqual(SleepStager.nightMotionRows(night, dayStart: dayStart), 6)
    }

    /// Noon before the day through noon on it. Both ends belong to the night; a second either side does
    /// not, which is what keeps the stale lookback out.
    func testTheSpanIsNoonToNoon() {
        XCTAssertEqual(SleepStager.nightMotionRows(grav([-12 * 3_600, 12 * 3_600]), dayStart: dayStart), 2)
        XCTAssertEqual(SleepStager.nightMotionRows(grav([-12 * 3_600 - 1, 12 * 3_600 + 1]), dayStart: dayStart), 0)
    }

    /// A ring that streams no gravity at all answers zero, as the window count did, so the paths that
    /// depend on "no motion" (an Oura's own hypnogram, #804) are reached exactly as before.
    func testNoMotionAtAllIsZero() {
        XCTAssertEqual(SleepStager.nightMotionRows([], dayStart: dayStart), 0)
    }

    /// Order is not assumed: the store hands rows ascending, but a caller that sorts differently must get
    /// the same count rather than a silently wrong one.
    func testTheRowsNeedNotBeSorted() {
        let shuffled = grav([6 * 3_600, -30 * 3_600, 0, -2 * 3_600, 20 * 3_600])
        XCTAssertEqual(SleepStager.nightMotionRows(shuffled, dayStart: dayStart), 3)
    }
}
