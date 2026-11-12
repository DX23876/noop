import XCTest
@testable import NoopCore

final class DriverUsualRangeTests: XCTestCase {
    func testMiddleHalfNeedsSevenNightsAndInterpolates() {
        XCTAssertNil(DriverUsualRange.middleHalf([1, 2, 3, 4, 5, 6]))
        let q = DriverUsualRange.middleHalf([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(q?.low ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(q?.high ?? 0, 7, accuracy: 1e-9)
    }

    func testPlaceKeepsTheRangeInTheMiddleThirdAndAFarValueOnTheTrack() {
        let inside = DriverUsualRange.place(5, low: 3, high: 7)
        XCTAssertEqual(inside.band.lowerBound, 100.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(inside.band.upperBound, 200.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(inside.position, 50, accuracy: 1e-9)
        let far = DriverUsualRange.place(30, low: 3, high: 7)
        XCTAssertLessThanOrEqual(far.position, 100)
        XCTAssertGreaterThan(far.position, far.band.upperBound)
    }
}
