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

/// The Today header's sync sweep, the ring the wearer watched stop (#48). Same reason as the breath: a
/// function of the clock, so a view that appears mid-cycle draws where the sweep IS.
final class SweepPhaseTests: XCTestCase {

    private let period = 1.1

    private func phase(_ seconds: Double) -> Double {
        StrandMotion.sweepPhase(at: Date(timeIntervalSinceReferenceDate: seconds), period: period)
    }

    /// It starts at rest and ends at the full sweep, then begins again — no reverse, as the ring draws.
    func testTheSweepRunsOutAndStartsOver() {
        XCTAssertEqual(phase(0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(phase(period * 0.99), 0.99)
        XCTAssertEqual(phase(period), 0, accuracy: 1e-9)
    }

    /// Inside one cycle it only moves forward: a ring that went backwards would read as a stutter.
    func testItOnlyGrowsWithinACycle() {
        var previous = -1.0
        for step in stride(from: 0.0, to: period, by: period / 20) {
            let value = phase(step)
            XCTAssertGreaterThan(value, previous, "at \(step)")
            previous = value
        }
    }

    /// Always inside 0…1, whatever instant it is asked about, including before the reference date.
    func testThePhaseStaysInsideItsRange() {
        for step in stride(from: -7.0, through: 12.0, by: 0.13) {
            XCTAssertGreaterThanOrEqual(phase(step), 0, "at \(step)")
            XCTAssertLessThanOrEqual(phase(step), 1, "at \(step)")
        }
    }

    /// Eased out: more than half the sweep is done by the halfway point.
    func testTheCurveEasesOut() {
        XCTAssertGreaterThan(phase(period * 0.5), 0.5)
    }

    func testAZeroPeriodRests() {
        XCTAssertEqual(StrandMotion.sweepPhase(at: Date(), period: 0), 0)
    }
}
