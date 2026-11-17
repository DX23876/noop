import XCTest
@testable import StrandDesign

/// The breath the live/sync dot draws, as a function of the clock (#48).
///
/// It is a function and not an animation because an animation has to be started and can be lost: the
/// sync dot stopped pulsing when the wearer switched tab and came back, and never started at all for a
/// sync that began while the screen was already open. A phase taken from the moment is right whenever it
/// is drawn, which is what these pin.
final class BreathPhaseTests: XCTestCase {

    private let period = StrandMotion.breathPeriod

    private func phase(_ seconds: Double) -> Double {
        StrandMotion.breathPhase(at: Date(timeIntervalSinceReferenceDate: seconds), period: period)
    }

    /// Rest at the start of a cycle, full swell half way, rest again at its end: the two frames the old
    /// animation travelled between, and back.
    func testTheCycleRestsSwellsAndRests() {
        XCTAssertEqual(phase(0), 0, accuracy: 1e-9)
        XCTAssertEqual(phase(period), 1, accuracy: 1e-9)
        XCTAssertEqual(phase(2 * period), 0, accuracy: 1e-9)
    }

    /// It never leaves 0…1, whatever instant it is asked about — a scale and an opacity are computed
    /// from it, and a value outside the range would draw a ring that grows without end or a negative
    /// opacity.
    func testThePhaseStaysInsideItsRange() {
        for step in stride(from: -10.0, through: 40.0, by: 0.37) {
            let value = phase(step)
            XCTAssertGreaterThanOrEqual(value, 0, "at \(step)")
            XCTAssertLessThanOrEqual(value, 1, "at \(step)")
        }
    }

    /// Time only moves forward, so the phase has to repeat: the same point of a later cycle draws the
    /// same frame. This is what makes the pulse recoverable — a view that appears mid-cycle draws where
    /// the breath IS, not where a freshly started animation would begin.
    func testEveryCycleDrawsTheSameFrames() {
        for offset in stride(from: 0.0, to: 2 * period, by: period / 8) {
            XCTAssertEqual(phase(offset), phase(offset + 2 * period), accuracy: 1e-9, "at \(offset)")
            XCTAssertEqual(phase(offset), phase(offset + 6 * period), accuracy: 1e-9, "at \(offset)")
        }
    }

    /// Slow in, slow out, as `breathe`'s own easeInOut draws it: the quarter point is below a straight
    /// line, the three-quarter point above it, and the middle is exactly half way.
    func testTheCurveEasesInAndOut() {
        XCTAssertLessThan(phase(period * 0.25), 0.25)
        XCTAssertEqual(phase(period * 0.5), 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(phase(period * 0.75), 0.75)
    }

    /// A period of zero cannot divide: it rests rather than producing a value nothing can draw.
    func testAZeroPeriodRests() {
        XCTAssertEqual(StrandMotion.breathPhase(at: Date(), period: 0), 0)
    }
}
