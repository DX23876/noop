import XCTest
@testable import Strand

/// Pins the span math behind the HR curve on the workout sheet: edges snap to whole minutes, a span never
/// shrinks below the one-minute floor, nothing reaches past now, and the framing keeps padding around it.
final class WorkoutSpanPickerTests: XCTestCase {

    private func t(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60) }
    private lazy var bounds = t(0)...t(240)
    private lazy var now = t(300)

    func testStartHandleSnapsAndStopsOneMinuteBeforeTheEnd() {
        let moved = WorkoutSpanPicker.applyDrag(.start, at: t(30.4), start: t(20), end: t(80),
                                                bounds: bounds, now: now)
        XCTAssertEqual(moved.start, t(30))
        XCTAssertEqual(moved.end, t(80))
        let pinned = WorkoutSpanPicker.applyDrag(.start, at: t(95), start: t(20), end: t(80),
                                                 bounds: bounds, now: now)
        XCTAssertEqual(pinned.start, t(79))
    }

    func testEndHandleCannotPassNow() {
        let moved = WorkoutSpanPicker.applyDrag(.end, at: t(239), start: t(20), end: t(80),
                                                bounds: bounds, now: t(200))
        XCTAssertEqual(moved.end, t(200))
    }

    func testMoveKeepsTheLengthInsideTheBounds() {
        let moved = WorkoutSpanPicker.applyDrag(.move(grabOffset: 10 * 60, length: 60 * 60), at: t(5),
                                                start: t(20), end: t(80), bounds: bounds, now: now)
        XCTAssertEqual(moved.start, t(0))
        XCTAssertEqual(moved.end, t(60))
    }

    func testDrawingBackwardsOrdersTheEdges() {
        let drawn = WorkoutSpanPicker.applyDrag(.create(anchor: t(120)), at: t(90), start: t(20), end: t(80),
                                                bounds: bounds, now: now)
        XCTAssertEqual(drawn.start, t(90))
        XCTAssertEqual(drawn.end, t(120))
    }

    func testFocusViewportPadsAndNeverPassesNow() {
        let v = WorkoutSpanPicker.focusViewport(start: t(100), end: t(130), now: t(150))
        XCTAssertEqual(v.upperBound, t(150))
        XCTAssertLessThanOrEqual(v.lowerBound, t(55))
        XCTAssertGreaterThanOrEqual(v.upperBound.timeIntervalSince(v.lowerBound), 2 * 3600)
    }
}
