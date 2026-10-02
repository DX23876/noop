import XCTest
@testable import StrandDesign

final class OrganicScoreMotionFilterTests: XCTestCase {
    func testGravityAndCounterImpulseAreClamped() {
        var filter = OrganicScoreMotionFilter()

        filter.update(
            gravity: OrganicScoreVector(x: 3, y: 4),
            acceleration: OrganicScoreVector(x: 5, y: 0),
            deltaTime: 1.0 / 60.0
        )

        XCTAssertLessThanOrEqual(filter.gravity.magnitude, 1)
        XCTAssertLessThanOrEqual(filter.impulse.magnitude, 1)
        XCTAssertLessThan(filter.impulse.x, 0, "the edge response counters the phone movement")
    }

    func testImpulseSettlesAndResetClearsAllMotion() {
        var filter = OrganicScoreMotionFilter()
        let gravity = OrganicScoreVector(x: 0.25, y: 0.75)
        filter.update(
            gravity: gravity,
            acceleration: OrganicScoreVector(x: -1.5, y: 0.8),
            deltaTime: 1.0 / 60.0
        )
        XCTAssertGreaterThan(filter.impulse.magnitude, 0)

        for _ in 0..<180 {
            filter.update(gravity: gravity, acceleration: .zero, deltaTime: 1.0 / 60.0)
        }
        XCTAssertLessThan(filter.impulse.magnitude, 0.001)

        filter.reset()
        XCTAssertEqual(filter.gravity, .zero)
        XCTAssertEqual(filter.impulse, .zero)
    }

    func testFilteringIsStableAcrossCommonFrameRates() {
        var thirtyFPS = OrganicScoreMotionFilter()
        var sixtyFPS = OrganicScoreMotionFilter()
        let gravity = OrganicScoreVector(x: 0.35, y: -0.65)
        let acceleration = OrganicScoreVector(x: 0.4, y: -0.2)

        for _ in 0..<30 {
            thirtyFPS.update(gravity: gravity, acceleration: acceleration, deltaTime: 1.0 / 30.0)
        }
        for _ in 0..<60 {
            sixtyFPS.update(gravity: gravity, acceleration: acceleration, deltaTime: 1.0 / 60.0)
        }

        XCTAssertEqual(thirtyFPS.gravity.x, sixtyFPS.gravity.x, accuracy: 0.000_001)
        XCTAssertEqual(thirtyFPS.gravity.y, sixtyFPS.gravity.y, accuracy: 0.000_001)
        XCTAssertEqual(thirtyFPS.impulse.x, sixtyFPS.impulse.x, accuracy: 0.000_001)
        XCTAssertEqual(thirtyFPS.impulse.y, sixtyFPS.impulse.y, accuracy: 0.000_001)
    }
}
