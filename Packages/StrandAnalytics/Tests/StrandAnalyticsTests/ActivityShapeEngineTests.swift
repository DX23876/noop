import XCTest
@testable import StrandAnalytics

final class ActivityShapeEngineTests: XCTestCase {

    /// A day whose activity sits in `hours`, one unit each.
    private func day(_ index: Int, hours: [Int]) -> ActivityShapeEngine.DayProfile {
        var slots = [Double](repeating: 0, count: 24)
        for hour in hours { slots[hour] = 200 }
        return .init(day: String(format: "2026-07-%02d", index + 1), activeByHour: slots)
    }

    private func morningPerson(days: Int) -> [ActivityShapeEngine.DayProfile] {
        (0..<days).map { day($0, hours: [6, 7, 8]) }
    }

    func testTooLittleHistoryOffersNoShapeAtAll() {
        XCTAssertNil(ActivityShapeEngine.fit(days: morningPerson(days: 6)))
        XCTAssertNotNil(ActivityShapeEngine.fit(days: morningPerson(days: 7)))
    }

    func testNearEmptyDaysAreNotNormalisedIntoAShape() {
        // 20 days of essentially nothing: dividing by a near-zero total would manufacture a shape.
        let quiet = (0..<20).map { index -> ActivityShapeEngine.DayProfile in
            var slots = [Double](repeating: 0, count: 24)
            slots[9] = 5   // below minimumDailyActiveKcal
            return .init(day: String(format: "2026-07-%02d", index + 1), activeByHour: slots)
        }
        XCTAssertNil(ActivityShapeEngine.fit(days: quiet))
    }

    func testMorningPersonHasBankedMostActivityByMidday() throws {
        let shape = try XCTUnwrap(ActivityShapeEngine.fit(days: morningPerson(days: 20)))
        // All the activity is 06:00-09:00, so by noon essentially all of it is done.
        let byNoon = shape.expectedFraction(elapsedSeconds: 12 * 3_600, dayDurationSeconds: 86_400)
        XCTAssertEqual(byNoon, 1.0, accuracy: 0.01)
        // And at 05:00 almost none of it is.
        let atFive = shape.expectedFraction(elapsedSeconds: 5 * 3_600, dayDurationSeconds: 86_400)
        XCTAssertLessThan(atFive, 0.05)
    }

    func testEveningPersonHasBarelyStartedByMidday() throws {
        let evening = (0..<20).map { day($0, hours: [18, 19, 20]) }
        let shape = try XCTUnwrap(ActivityShapeEngine.fit(days: evening))
        let byNoon = shape.expectedFraction(elapsedSeconds: 12 * 3_600, dayDurationSeconds: 86_400)
        XCTAssertLessThan(byNoon, 0.05)
        let byNine = shape.expectedFraction(elapsedSeconds: 21 * 3_600, dayDurationSeconds: 86_400)
        XCTAssertEqual(byNine, 1.0, accuracy: 0.01)
    }

    /// The curve is a SHAPE: one enormous day must not outvote twenty ordinary ones, which is what
    /// per-day normalisation before combining buys.
    func testOneHugeDayDoesNotRedefineTheShape() throws {
        var days = morningPerson(days: 20)
        var marathon = [Double](repeating: 0, count: 24)
        marathon[20] = 40_000                     // one colossal evening
        days.append(.init(day: "2026-07-21", activeByHour: marathon))

        let shape = try XCTUnwrap(ActivityShapeEngine.fit(days: days))
        let byNoon = shape.expectedFraction(elapsedSeconds: 12 * 3_600, dayDurationSeconds: 86_400)
        XCTAssertGreaterThan(byNoon, 0.90, "a single outlier day must not move a 20-day median shape")
    }

    func testCurveIsMonotoneBoundedAndComplete() throws {
        let mixed = (0..<20).map { day($0, hours: [7, 12, 18]) }
        let shape = try XCTUnwrap(ActivityShapeEngine.fit(days: mixed))
        XCTAssertEqual(shape.cumulativeByHour.count, 24)
        XCTAssertEqual(shape.cumulativeByHour.last, 1.0)
        for (a, b) in zip(shape.cumulativeByHour, shape.cumulativeByHour.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "cumulative curve must never go backwards")
        }
        XCTAssertTrue(shape.cumulativeByHour.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// A 23- or 25-hour DST day still maps onto the curve, because the question is asked as a
    /// fraction of the REAL local day rather than of a fixed 86,400.
    func testDaylightSavingDayMapsOntoTheCurve() throws {
        let shape = try XCTUnwrap(ActivityShapeEngine.fit(days: morningPerson(days: 20)))
        let short = shape.expectedFraction(elapsedSeconds: 23 * 3_600, dayDurationSeconds: 23 * 3_600)
        XCTAssertEqual(short, 1.0, accuracy: 0.001)
    }
}
