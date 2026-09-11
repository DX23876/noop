import XCTest
@testable import StrandAnalytics

/// Pins the Hodgdon & Beckett circumference estimate.
///
/// The expected values are computed from the published equations independently of this
/// implementation, so the test verifies the FORMULA rather than agreeing with whatever the code does.
final class NavyBodyFatTests: XCTestCase {

    /// The male equation against an independently computed reference point.
    func testTheMaleEquationMatchesItsPublishedForm() {
        let value = NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 38, waistCm: 85)
        XCTAssertEqual(try XCTUnwrap(value), 16.1066, accuracy: 0.001)
    }

    /// The female equation, which takes a hip measurement the male one does not.
    func testTheFemaleEquationMatchesItsPublishedForm() {
        let value = NavyBodyFat.percent(equation: .female, heightCm: 165, neckCm: 32,
                                        waistCm: 70, hipCm: 95)
        XCTAssertEqual(try XCTUnwrap(value), 24.8562, accuracy: 0.001)
    }

    /// A larger waist at equal height and neck reads higher — the direction the whole estimate rests
    /// on, and the property that makes the trend usable even where the level is not.
    func testAGreaterWaistReadsHigher() throws {
        let lean = try XCTUnwrap(NavyBodyFat.percent(equation: .male, heightCm: 180,
                                                     neckCm: 38, waistCm: 85))
        let heavier = try XCTUnwrap(NavyBodyFat.percent(equation: .male, heightCm: 180,
                                                        neckCm: 38, waistCm: 95))
        XCTAssertGreaterThan(heavier, lean)
        XCTAssertEqual(heavier, 23.2283, accuracy: 0.001)
    }

    /// The female equation needs a hip measurement and says nothing without one, rather than falling
    /// through to the male equation — they were fitted on different cohorts and are not substitutes.
    func testTheFemaleEquationRefusesWithoutAHipMeasurement() {
        XCTAssertNil(NavyBodyFat.percent(equation: .female, heightCm: 165, neckCm: 32, waistCm: 70))
        XCTAssertTrue(NavyEquation.female.needsHip)
        XCTAssertFalse(NavyEquation.male.needsHip)
    }

    /// A hip measurement handed to the male equation is ignored, not quietly folded in.
    func testTheMaleEquationIgnoresAHipMeasurement() {
        let without = NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 38, waistCm: 85)
        let with = NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 38,
                                       waistCm: 85, hipCm: 95)
        XCTAssertEqual(try XCTUnwrap(without), try XCTUnwrap(with), accuracy: 1e-12)
    }

    /// Neck and waist swapped — the commonest tape error — makes the logarithm undefined. The answer
    /// is nothing, which surfaces the mistake; a clamped number would hide it.
    func testSwappedNeckAndWaistProduceNothing() {
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 85, waistCm: 38))
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 85, waistCm: 85))
    }

    /// A result below what a body can carry is refused rather than reported. These measurements are
    /// arithmetically fine and yield 0.33 % — almost always inches entered into a centimetre field.
    func testAnImpossiblyLowResultIsRefused() {
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 38, waistCm: 68))
    }

    /// Missing, zero and non-finite measurements produce nothing.
    func testAbsentMeasurementsProduceNothing() {
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 0, neckCm: 38, waistCm: 85))
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 0, waistCm: 85))
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: 180, neckCm: 38, waistCm: 0))
        XCTAssertNil(NavyBodyFat.percent(equation: .male, heightCm: .nan, neckCm: 38, waistCm: 85))
        XCTAssertNil(NavyBodyFat.percent(equation: .female, heightCm: 165, neckCm: 32,
                                         waistCm: 70, hipCm: 0))
    }

    /// The error band is carried on the type so no surface has to restate it from memory.
    func testTheErrorBandIsPublished() {
        XCTAssertEqual(NavyBodyFat.errorBandPercentagePoints, 4.0)
        XCTAssertEqual(NavyBodyFat.plausibleRange, 3...70)
    }
}
