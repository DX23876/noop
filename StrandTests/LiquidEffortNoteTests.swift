import XCTest
@testable import Strand

/// Pins the Liquid Today "no cardio load yet" Effort note (#530 follow-up — parity with the classic
/// `TodayView.effortZeroNote`). The gate is pure, so it pins with no strap, no clock, and no view: the
/// note appears ONLY for today when a real strain value exists and is ~0 — a genuinely calm day. A
/// no-data day (nil strain) shows its own ring overlay instead, and a navigated past day is never
/// annotated.
final class LiquidEffortNoteTests: XCTestCase {

    private typealias Display = LiquidTodayView.EffortDisplay

    func testCalmTodayShowsTheNote() {
        XCTAssertTrue(Display.showsZeroNote(strain: 0.0, isToday: true))
        XCTAssertTrue(Display.showsZeroNote(strain: 0.9, isToday: true))
    }

    func testEffortAtOrAboveOneDoesNotShow() {
        // The gauge reads a real number at ≥ 1.0, so the "near zero" note would be a false statement.
        XCTAssertFalse(Display.showsZeroNote(strain: 1.0, isToday: true))
        XCTAssertFalse(Display.showsZeroNote(strain: 38.3, isToday: true))
    }

    func testNoStrainValueDoesNotShow() {
        // A no-data day shows its own ring overlay; the Effort note must not annotate it.
        XCTAssertFalse(Display.showsZeroNote(strain: nil, isToday: true))
    }

    func testPastDayIsNeverAnnotated() {
        XCTAssertFalse(Display.showsZeroNote(strain: 0.0, isToday: false))
        XCTAssertFalse(Display.showsZeroNote(strain: nil, isToday: false))
    }
}
